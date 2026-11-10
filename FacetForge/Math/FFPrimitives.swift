import Foundation

/// The five primitives Phase 41 adds. Each is a closed planar curve defined by a
/// handful of parameters, not by the points it happens to be drawn with, which
/// is what makes it editable after creation.
enum FFCurvePrimitiveKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case circle
    case ellipse
    case rectangle
    case roundedRectangle
    case polygon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: return "Circle"
        case .ellipse: return "Ellipse"
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded rectangle"
        case .polygon: return "Polygon"
        }
    }
}

/// One editable parameter of a primitive. The field exists so a panel or a
/// command can say *what* to change without duplicating the per-kind rules,
/// and so diameter stays a first-class input even though the shape stores a
/// radius.
enum FFPrimitiveField: String, CaseIterable, Sendable {
    case radius
    case diameter
    case width
    case height
    case cornerRadius
    case sides

    var label: String {
        switch self {
        case .radius: return "Radius"
        case .diameter: return "Diameter"
        case .width: return "Width"
        case .height: return "Height"
        case .cornerRadius: return "Corner radius"
        case .sides: return "Sides"
        }
    }
}

/// A parametric primitive curve. It lives in the document beside the ordinary
/// curve payload that it generates: the payload is what the renderer, export
/// and undo already know, and this record is what makes the shape editable
/// afterwards. Every primitive is planar with its centre in the sketch plane
/// (z = 0), so an edit can change size or side count but never move it off its
/// plane or away from its position.
struct FFCurvePrimitive: Codable, Equatable, Sendable {
    var kind: FFCurvePrimitiveKind
    var center: FFPoint2
    /// Circle radius and polygon circumradius, in millimetres.
    var radius: Double
    /// Ellipse and rectangle full width, in millimetres.
    var width: Double
    /// Ellipse and rectangle full height, in millimetres.
    var height: Double
    /// Rounded rectangle corner radius, in millimetres.
    var cornerRadius: Double
    /// Regular polygon edge count.
    var sides: Int

    init(
        kind: FFCurvePrimitiveKind,
        center: FFPoint2 = FFPoint2(x: 0, y: 0),
        radius: Double = 5,
        width: Double = 12,
        height: Double = 8,
        cornerRadius: Double = 1.5,
        sides: Int = 6
    ) {
        self.kind = kind
        self.center = center
        self.radius = radius
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.sides = sides
    }

    var diameter: Double { radius * 2 }

    /// The rule that decides whether this record can produce a curve. It is the
    /// only validation source: the document and the session both call it, so a
    /// panel's enabled state and a command cannot disagree.
    var isValid: Bool {
        guard center.x.isFinite, center.y.isFinite else { return false }
        switch kind {
        case .circle:
            return radius.isFinite && radius > FFMath.eps
        case .ellipse, .rectangle:
            return width.isFinite && height.isFinite
                && width > FFMath.eps && height > FFMath.eps
        case .roundedRectangle:
            guard width.isFinite, height.isFinite, cornerRadius.isFinite,
                  width > FFMath.eps, height > FFMath.eps, cornerRadius >= 0
            else { return false }
            return cornerRadius <= min(width, height) / 2 + 1e-9
        case .polygon:
            return radius.isFinite && radius > FFMath.eps
                && sides >= 3 && sides <= 1024
        }
    }

    /// Applies one parameter edit, refusing a field the kind does not have and
    /// any value that would leave the primitive invalid. Returns true only when
    /// the record actually changed.
    @discardableResult
    mutating func set(_ field: FFPrimitiveField, to value: Double) -> Bool {
        guard value.isFinite else { return false }
        let before = self
        switch field {
        case .radius:
            guard kind == .circle || kind == .polygon, value > FFMath.eps else { return false }
            radius = value
        case .diameter:
            guard kind == .circle, value > 2 * FFMath.eps else { return false }
            radius = value / 2
        case .width:
            guard kind == .ellipse || kind == .rectangle || kind == .roundedRectangle,
                  value > FFMath.eps
            else { return false }
            width = value
        case .height:
            guard kind == .ellipse || kind == .rectangle || kind == .roundedRectangle,
                  value > FFMath.eps
            else { return false }
            height = value
        case .cornerRadius:
            guard kind == .roundedRectangle, value >= 0 else { return false }
            cornerRadius = value
        case .sides:
            guard kind == .polygon else { return false }
            let count = value.rounded()
            guard abs(value - count) < 1e-9, count >= 3, count <= 1024 else { return false }
            sides = Int(count)
        }
        guard isValid, self != before else {
            self = before
            return false
        }
        return true
    }

    /// The exact curve this record stands for, in the existing payload.
    func payload() throws -> FFCurvePayload {
        try FFPrimitiveGeometry.payload(for: self)
    }

    /// A short, display-ready description of the parameter that matters most
    /// for the kind, in the document's unit. Views format it, never compute it.
    func summary(unit: FFLengthUnit) -> String {
        switch kind {
        case .circle:
            return "Ø \(FFPrecision.lengthString(millimetres: diameter, unit: unit))"
        case .ellipse:
            return "\(FFPrecision.lengthString(millimetres: width, unit: unit)) × \(FFPrecision.lengthString(millimetres: height, unit: unit))"
        case .rectangle:
            return "\(FFPrecision.lengthString(millimetres: width, unit: unit)) × \(FFPrecision.lengthString(millimetres: height, unit: unit))"
        case .roundedRectangle:
            return "\(FFPrecision.lengthString(millimetres: width, unit: unit)) × \(FFPrecision.lengthString(millimetres: height, unit: unit)) · R \(FFPrecision.lengthString(millimetres: cornerRadius, unit: unit))"
        case .polygon:
            return "\(sides) sides · \(FFPrecision.lengthString(millimetres: radius, unit: unit)) radius"
        }
    }
}

/// Why a primitive could not be built or edited. Every case carries a sentence
/// so a refusal explains itself rather than silently doing nothing.
enum FFPrimitiveError: Error, Equatable, LocalizedError {
    case notFinite
    case nonPositiveSize
    case cornerTooLarge(maximum: Double)
    case tooFewSides
    case fieldNotAvailable

    var errorDescription: String? {
        switch self {
        case .notFinite:
            return "A primitive needs finite values"
        case .nonPositiveSize:
            return "A primitive needs a radius or size greater than zero"
        case .cornerTooLarge(let maximum):
            return "A corner radius must be between zero and half the shorter side (\(FFPrecision.lengthString(millimetres: maximum, unit: .millimetres)))"
        case .tooFewSides:
            return "A polygon needs a whole number of sides, at least three"
        case .fieldNotAvailable:
            return "That parameter does not apply to this primitive"
        }
    }
}

/// Turns a parametric primitive into exact curve segments in the payload the
/// document already stores, so no format byte, schema revision or canonical
/// hash changes because of Phase 41.
///
/// Circles and ellipses are four rational quadratic quarter spans with weight
/// `cos(45°) = √2/2`, which is exact for a conic. Rectangles and polygons are
/// line segments. A rounded rectangle is four lines and four quarter arcs, and
/// a zero corner radius degenerates to the plain rectangle rather than to
/// four zero-radius curves.
enum FFPrimitiveGeometry {
    static let quarterTurn = Double.pi / 2

    static func payload(for primitive: FFCurvePrimitive) throws -> FFCurvePayload {
        guard primitive.isValid else { throw error(for: primitive) }
        let center = primitive.center.vector

        switch primitive.kind {
        case .circle:
            let segments = (0..<4).map { index in
                circularQuarter(
                    center: center,
                    radius: primitive.radius,
                    startAngle: Double(index) * quarterTurn
                )
            }
            return FFCurvePayload(segments: segments, isClosed: true)

        case .ellipse:
            let halfWidth = primitive.width / 2
            let halfHeight = primitive.height / 2
            let segments = (0..<4).map { index in
                ellipticalQuarter(
                    center: center,
                    halfWidth: halfWidth,
                    halfHeight: halfHeight,
                    startAngle: Double(index) * quarterTurn
                )
            }
            return FFCurvePayload(segments: segments, isClosed: true)

        case .rectangle:
            return FFCurvePayload(
                segments: rectangleSegments(
                    center: center,
                    halfWidth: primitive.width / 2,
                    halfHeight: primitive.height / 2
                ),
                isClosed: true
            )

        case .roundedRectangle:
            if primitive.cornerRadius <= FFMath.eps {
                return FFCurvePayload(
                    segments: rectangleSegments(
                        center: center,
                        halfWidth: primitive.width / 2,
                        halfHeight: primitive.height / 2
                    ),
                    isClosed: true
                )
            }
            return FFCurvePayload(
                segments: roundedRectangleSegments(
                    center: center,
                    halfWidth: primitive.width / 2,
                    halfHeight: primitive.height / 2,
                    cornerRadius: primitive.cornerRadius
                ),
                isClosed: true
            )

        case .polygon:
            let count = primitive.sides
            let startAngle = quarterTurn
            let points = (0..<count).map { index -> Vec2 in
                let angle = startAngle + 2 * Double.pi * Double(index) / Double(count)
                return center + Vec2(x: cos(angle), y: sin(angle)) * primitive.radius
            }
            let segments = (0..<count).map { index in
                line(points[index], points[(index + 1) % count])
            }
            return FFCurvePayload(segments: segments, isClosed: true)
        }
    }

    /// A quarter of a circle, exact as one rational quadratic span. The control
    /// point is the intersection of the tangents at the endpoints, which for a
    /// quarter turn is one radius along the tangent from the start.
    static func circularQuarter(
        center: Vec2,
        radius: Double,
        startAngle: Double
    ) -> FFCurveSegment {
        let endAngle = startAngle + quarterTurn
        let startPoint = center + Vec2(x: cos(startAngle), y: sin(startAngle)) * radius
        let endPoint = center + Vec2(x: cos(endAngle), y: sin(endAngle)) * radius
        let tangent = Vec2(x: -sin(startAngle), y: cos(startAngle))
        let controlPoint = startPoint + tangent * radius
        return rationalQuadratic(startPoint, controlPoint, endPoint)
    }

    /// A quarter of an axis-aligned ellipse. The same rational quadratic span
    /// works for any conic when the control point is the tangent intersection:
    /// for parameter angles `t` and `t + 90°` that is
    /// `(a cos m, b sin m) / cos 45°` with `m` the mid-parameter.
    static func ellipticalQuarter(
        center: Vec2,
        halfWidth: Double,
        halfHeight: Double,
        startAngle: Double
    ) -> FFCurveSegment {
        let endAngle = startAngle + quarterTurn
        let middle = startAngle + quarterTurn / 2
        let cosine = cos(quarterTurn / 2)
        let startPoint = center + Vec2(
            x: halfWidth * cos(startAngle),
            y: halfHeight * sin(startAngle)
        )
        let endPoint = center + Vec2(
            x: halfWidth * cos(endAngle),
            y: halfHeight * sin(endAngle)
        )
        let controlPoint = center + Vec2(
            x: halfWidth * cos(middle) / cosine,
            y: halfHeight * sin(middle) / cosine
        )
        return rationalQuadratic(startPoint, controlPoint, endPoint)
    }

    static func rectangleSegments(
        center: Vec2,
        halfWidth: Double,
        halfHeight: Double
    ) -> [FFCurveSegment] {
        let corners = [
            center + Vec2(x: -halfWidth, y: -halfHeight),
            center + Vec2(x: halfWidth, y: -halfHeight),
            center + Vec2(x: halfWidth, y: halfHeight),
            center + Vec2(x: -halfWidth, y: halfHeight),
        ]
        return (0..<4).map { index in
            line(corners[index], corners[(index + 1) % 4])
        }
    }

    static func roundedRectangleSegments(
        center: Vec2,
        halfWidth: Double,
        halfHeight: Double,
        cornerRadius: Double
    ) -> [FFCurveSegment] {
        let radius = cornerRadius
        let bottomRight = Vec2(x: center.x + halfWidth - radius, y: center.y - halfHeight + radius)
        let topRight = Vec2(x: center.x + halfWidth - radius, y: center.y + halfHeight - radius)
        let topLeft = Vec2(x: center.x - halfWidth + radius, y: center.y + halfHeight - radius)
        let bottomLeft = Vec2(x: center.x - halfWidth + radius, y: center.y - halfHeight + radius)

        return [
            line(
                Vec2(x: center.x - halfWidth + radius, y: center.y - halfHeight),
                Vec2(x: center.x + halfWidth - radius, y: center.y - halfHeight)
            ),
            circularQuarter(center: bottomRight, radius: radius, startAngle: -quarterTurn),
            line(
                Vec2(x: center.x + halfWidth, y: center.y - halfHeight + radius),
                Vec2(x: center.x + halfWidth, y: center.y + halfHeight - radius)
            ),
            circularQuarter(center: topRight, radius: radius, startAngle: 0),
            line(
                Vec2(x: center.x + halfWidth - radius, y: center.y + halfHeight),
                Vec2(x: center.x - halfWidth + radius, y: center.y + halfHeight)
            ),
            circularQuarter(center: topLeft, radius: radius, startAngle: quarterTurn),
            line(
                Vec2(x: center.x - halfWidth, y: center.y + halfHeight - radius),
                Vec2(x: center.x - halfWidth, y: center.y - halfHeight + radius)
            ),
            circularQuarter(center: bottomLeft, radius: radius, startAngle: Double.pi),
        ]
    }

    private static func rationalQuadratic(
        _ start: Vec2,
        _ control: Vec2,
        _ end: Vec2
    ) -> FFCurveSegment {
        let weight = cos(quarterTurn / 2)
        return FFCurveSegment(
            kind: .nurbs,
            controlPoints: [FFPoint2(start), FFPoint2(control), FFPoint2(end)],
            weights: [1, weight, 1],
            degree: 2,
            knots: [0, 0, 0, 1, 1, 1]
        )
    }

    private static func line(_ start: Vec2, _ end: Vec2) -> FFCurveSegment {
        FFCurveSegment(kind: .bezier, controlPoints: [FFPoint2(start), FFPoint2(end)])
    }

    private static func error(for primitive: FFCurvePrimitive) -> FFPrimitiveError {
        guard primitive.center.x.isFinite, primitive.center.y.isFinite else { return .notFinite }
        switch primitive.kind {
        case .circle:
            return primitive.radius.isFinite ? .nonPositiveSize : .notFinite
        case .ellipse, .rectangle:
            return primitive.width.isFinite && primitive.height.isFinite ? .nonPositiveSize : .notFinite
        case .roundedRectangle:
            guard primitive.width.isFinite, primitive.height.isFinite,
                  primitive.cornerRadius.isFinite
            else { return .notFinite }
            return .cornerTooLarge(maximum: min(primitive.width, primitive.height) / 2)
        case .polygon:
            guard primitive.radius.isFinite else { return .notFinite }
            return primitive.sides < 3 ? .tooFewSides : .nonPositiveSize
        }
    }
}
