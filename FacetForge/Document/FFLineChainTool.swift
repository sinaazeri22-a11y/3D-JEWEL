import Foundation

/// One measured line segment: its exact length and its direction in the sketch
/// plane, measured from +X counter-clockwise. Angles are normalised to
/// 0..<360 so a readout never shows a negative bearing.
struct FFLineSegmentMeasure: Equatable, Sendable {
    var lengthMM: Double
    var angleDegrees: Double

    func lengthString(unit: FFLengthUnit) -> String {
        FFPrecision.lengthString(millimetres: lengthMM, unit: unit)
    }

    var angleString: String {
        FFPrecision.angleString(degrees: angleDegrees)
    }

    init(lengthMM: Double, angleDegrees: Double) {
        self.lengthMM = lengthMM
        self.angleDegrees = angleDegrees
    }

    init(from start: Vec2, to end: Vec2) {
        let delta = end - start
        self.lengthMM = delta.length
        self.angleDegrees = Self.normalisedAngle(delta)
    }

    static func normalisedAngle(_ delta: Vec2) -> Double {
        guard delta.length > FFMath.eps else { return 0 }
        var degrees = atan2(delta.y, delta.x) * 180 / Double.pi
        if degrees < 0 { degrees += 360 }
        // atan2 can return -0 for a direction on the positive X axis after the
        // adjustment; a readout must not inherit that sign.
        return degrees == 0 ? 0 : degrees
    }
}

/// Why a line command was refused. Every case carries a sentence: a tool that
/// silently does nothing is the failure this row exists to prevent.
enum FFLineChainError: Error, Equatable, LocalizedError {
    case noDirection
    case invalidLength(String)
    case nonPositiveLength(Double)
    case duplicatePoint
    case tooFewPoints(Int)
    case tooFewPointsToClose(Int)
    case chainAlreadyClosed

    var errorDescription: String? {
        switch self {
        case .noDirection:
            return "Move the pointer to set a direction before typing a length"
        case .invalidLength(let text):
            let shown = text.isEmpty ? "nothing" : "\"\(text)\""
            return "\(shown) is not a length"
        case .nonPositiveLength(let value):
            return "A segment length must be greater than zero (\(FFPrecision.lengthString(millimetres: value, unit: .millimetres)) was refused)"
        case .duplicatePoint:
            return "That point is on the previous vertex; a segment needs a length"
        case .tooFewPoints(let count):
            return "A line chain needs at least two vertices, not \(count)"
        case .tooFewPointsToClose(let count):
            return "A closed chain needs at least three vertices; this one has \(count)"
        case .chainAlreadyClosed:
            return "This chain is already closed; press Finish to keep it"
        }
    }
}

/// The live line chain, in the document's world XY sketch plane.
///
/// The draft owns only transient tool state. `payload()` produces the curve the
/// document stores, so the file format sees an ordinary `FFCurvePayload` and no
/// new document field or schema revision is needed. Every segment is a
/// two-point Bézier, which the kernel already treats as a straight line.
struct FFLineChainDraft: Equatable, Sendable {
    private(set) var points: [Vec2] = []
    private(set) var pending: Vec2?
    private(set) var isClosed = false

    var isActive: Bool { !points.isEmpty }
    var canClose: Bool { !isClosed && points.count >= 3 }

    /// Segments already committed, including the closing segment once closed.
    var segmentCount: Int {
        guard points.count >= 2 else { return 0 }
        return points.count - 1 + (isClosed ? 1 : 0)
    }

    var committedMeasures: [FFLineSegmentMeasure] {
        var result: [FFLineSegmentMeasure] = []
        for index in 0..<max(0, points.count - 1) {
            result.append(FFLineSegmentMeasure(from: points[index], to: points[index + 1]))
        }
        if isClosed, let first = points.first, let last = points.last, points.count >= 3 {
            result.append(FFLineSegmentMeasure(from: last, to: first))
        }
        return result
    }

    /// The live length and angle from the last vertex to the pending point.
    /// `nil` when no direction has been established yet.
    var pendingMeasure: FFLineSegmentMeasure? {
        guard let last = points.last, let pending else { return nil }
        guard pending.distance(to: last) > FFMath.eps else { return nil }
        return FFLineSegmentMeasure(from: last, to: pending)
    }

    /// Closing detection: the pending point is the chain's first vertex, so a
    /// tap there closes the loop instead of adding a duplicate vertex.
    var wouldClose: Bool {
        guard canClose, let pending, let first = points.first else { return false }
        return pending.distance(to: first) <= FFTolerance.curveJoin
    }

    mutating func begin(at point: Vec2) {
        points = [point]
        pending = nil
        isClosed = false
    }

    mutating func preview(to point: Vec2) {
        guard isActive, !isClosed else { return }
        pending = point
    }

    mutating func clearPreview() {
        pending = nil
    }

    mutating func cancel() {
        self = FFLineChainDraft()
    }

    /// Commits the pending point. Returns true when that point closed the
    /// chain. A duplicate vertex is refused rather than stored as a
    /// zero-length segment.
    @discardableResult
    mutating func commitPending() throws -> Bool {
        guard !isClosed else { throw FFLineChainError.chainAlreadyClosed }
        guard let point = pending else { throw FFLineChainError.noDirection }
        if wouldClose {
            isClosed = true
            pending = nil
            return true
        }
        guard let last = points.last else { throw FFLineChainError.noDirection }
        guard point.distance(to: last) > FFTolerance.curveJoin else {
            throw FFLineChainError.duplicatePoint
        }
        points.append(point)
        pending = nil
        return false
    }

    /// The typed-length entry. The pending direction decides where the segment
    /// points; the typed number decides how far it goes, so a dimension never
    /// depends on pointer accuracy.
    @discardableResult
    mutating func commitTypedLength(_ millimetres: Double) throws -> Bool {
        guard millimetres.isFinite, millimetres > 0 else {
            throw FFLineChainError.nonPositiveLength(millimetres)
        }
        guard let last = points.last, let pending else {
            throw FFLineChainError.noDirection
        }
        guard let direction = (pending - last).normalized() else {
            throw FFLineChainError.noDirection
        }
        let target = last + direction * millimetres
        self.pending = target
        return try commitPending()
    }

    /// Closes the chain geometrically: the last vertex joins the first.
    mutating func close() throws {
        guard !isClosed else { return }
        guard points.count >= 3 else {
            throw FFLineChainError.tooFewPointsToClose(points.count)
        }
        isClosed = true
        pending = nil
    }

    /// The curve this chain stores. Throws rather than producing a payload the
    /// reader would reject.
    func payload() throws -> FFCurvePayload {
        guard points.count >= 2 else {
            throw FFLineChainError.tooFewPoints(points.count)
        }
        var segments: [FFCurveSegment] = []
        for index in 0..<(points.count - 1) {
            segments.append(Self.lineSegment(from: points[index], to: points[index + 1]))
        }
        if isClosed, let first = points.first, let last = points.last {
            segments.append(Self.lineSegment(from: last, to: first))
        }
        guard !segments.isEmpty else {
            throw FFLineChainError.tooFewPoints(points.count)
        }
        return FFCurvePayload(segments: segments, isClosed: isClosed)
    }

    private static func lineSegment(from start: Vec2, to end: Vec2) -> FFCurveSegment {
        FFCurveSegment(
            kind: .bezier,
            controlPoints: [FFPoint2(start), FFPoint2(end)]
        )
    }
}

/// Turns a viewport tap into a point on a sketch plane. A snap wins when one is
/// within finger tolerance; otherwise the tap's ray is cast onto `plane`, which
/// defaults to the world XY plane a first sketch is drawn on. Phase 50 passes the
/// plane a sketch is locked to, so the same snapping and the same refusal serve
/// both tools instead of a second placement rule existing beside this one.
enum FFLineChainPlacement {
    static let fingerTolerance: Double = 12

    static func point(
        at tap: Vec2,
        scene: FFViewportScene,
        camera: FFCamera,
        viewport: Vec2,
        plane: FFPlane3D = .ground,
        draftPoints: [Vec2] = [],
        tolerance: Double = FFLineChainPlacement.fingerTolerance
    ) -> Vec2? {
        guard viewport.x > FFMath.eps, viewport.y > FFMath.eps,
              tap.x.isFinite, tap.y.isFinite, tolerance > 0
        else { return nil }

        // The chain's own vertices are snap features too. Without this a tap on
        // the first vertex would land somewhere near it and never close the
        // loop, because closing is an exact identity on the stored point.
        for point in draftPoints {
            let world = plane.embed(point)
            guard let screen = camera.screenPoint(for: world, viewport: viewport) else { continue }
            if (tap - screen).length <= tolerance {
                return point
            }
        }

        let geometry = FFSnapGeometry.features(
            of: scene,
            selectedIDs: Set(scene.nodes.filter(\.isVisible).map(\.id))
        )
        if let result = FFSnapResolver.resolve(
            hover: tap,
            reference: nil,
            geometry: geometry,
            camera: camera,
            viewport: viewport,
            tolerance: tolerance
        ) {
            return plane.coordinates(of: result.best.position)
        }

        guard let ray = camera.ray(at: tap, viewport: viewport) else { return nil }
        return plane.sketchPoint(of: ray)
    }
}

/// A curve node as the overlay draws it: world-space points, already walked
/// through every parent transform. The session owns this projection so the
/// view never has to know how a node composes its matrix.
struct FFCurveRender: Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isClosed: Bool
    var layerID: UUID?
    var worldPoints: [Vec3]
}

extension FFCurvePayload {
    /// Points for drawing. Each segment is sampled from its kernel curve so a
    /// later arc or spline renders through the same path; joints are not
    /// duplicated.
    func renderPoints(samplesPerSegment: Int = 8) -> [Vec3]? {
        var result: [Vec3] = []
        let samples = max(2, samplesPerSegment)
        for segment in segments {
            guard let curve = segment.curve else { return nil }
            for step in 0...samples {
                if step == 0, !result.isEmpty { continue }
                let t = Double(step) / Double(samples)
                let point = curve.point(at: t)
                guard point.x.isFinite, point.y.isFinite else { return nil }
                result.append(Vec3(x: point.x, y: point.y, z: 0))
            }
        }
        guard result.count >= 2 else { return nil }
        return result
    }
}

extension FFDocument {
    /// Every curve node in the document, in the same pre-order the object tree
    /// uses, with its points in world space.
    func curveRenders() -> [FFCurveRender] {
        var result: [FFCurveRender] = []

        func visit(_ node: FFNode, parent: Mat4) {
            let world = parent * node.localMatrix
            // A curve follows the same visibility the mesh scene uses: a hidden
            // node or a hidden layer does not draw, and the overlay must not
            // disagree with the object tree about what is on screen.
            let isDrawn = node.isVisible && (layer(forNodeID: node.id)?.isVisible ?? true)
            if isDrawn,
               let payload = node.geometry?.curve,
               let points = payload.renderPoints(),
               points.count >= 2 {
                let transformed = points.map { point -> Vec3 in
                    let value = world * Vec4(x: point.x, y: point.y, z: point.z, w: 1)
                    guard abs(value.w) > FFMath.eps else { return point }
                    return Vec3(
                        x: value.x / value.w,
                        y: value.y / value.w,
                        z: value.z / value.w
                    )
                }
                result.append(FFCurveRender(
                    id: node.id,
                    name: node.name,
                    isClosed: payload.isClosed,
                    layerID: node.layerID,
                    worldPoints: transformed
                ))
            }
            for child in node.children {
                visit(child, parent: world)
            }
        }

        for root in rootNodes {
            visit(root, parent: .identity)
        }
        return result
    }

    /// Names already taken by curve nodes, so a new chain never collides with
    /// one the user renamed or a future template writes.
    func curveNodeNames() -> Set<String> {
        var names: Set<String> = []
        func visit(_ node: FFNode) {
            if node.geometry?.curve != nil {
                names.insert(node.name)
            }
            for child in node.children { visit(child) }
        }
        for root in rootNodes { visit(root) }
        return names
    }
}
