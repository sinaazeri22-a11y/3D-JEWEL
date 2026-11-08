import Foundation

/// Display units. Geometry is stored in millimetres at double precision; this
/// type only converts and formats for people, so no kernel value ever depends
/// on the unit currently shown.
enum FFLengthUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case millimetres
    case inches

    static let millimetresPerInch = 25.4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .millimetres: "mm"
        case .inches: "in"
        }
    }

    var name: String {
        switch self {
        case .millimetres: "Millimetres"
        case .inches: "Inches"
        }
    }

    func value(fromMillimetres millimetres: Double) -> Double {
        switch self {
        case .millimetres: millimetres
        case .inches: millimetres / Self.millimetresPerInch
        }
    }

    func millimetres(from value: Double) -> Double {
        switch self {
        case .millimetres: value
        case .inches: value * Self.millimetresPerInch
        }
    }

    /// Formats a millimetre value in this unit. The suffix is part of the
    /// string so labels stay unambiguous when copied into notes.
    /// A caller must name its decimals: the measurement policy lives in
    /// `FFPrecision`, and a silent default here is how a view would invent its
    /// own precision. Display values use `FFPrecision.lengthString` instead.
    func formatted(millimetres: Double, decimals: Int) -> String {
        let value = value(fromMillimetres: millimetres)
        return FFPrecision.fixed(value, decimals: decimals) + " " + label
    }
}

/// US ring size. Inner diameter in millimetres is the source of truth, per the
/// domain dossier; the US and ISO labels are derived views of that value.
///
/// The US conversion is a trade convention (`d = 0.8128 x size + 11.63`), not
/// an ISO formula. ISO 8653 defines a size by its inner circumference, which
/// `isoCircumferenceMM` exposes exactly.
struct FFRingSize: Equatable, Comparable, Sendable {
    static let diameterInterceptMM = 11.63
    static let diameterPerUSSizeMM = 0.8128

    private(set) var innerDiameterMM: Double

    init(innerDiameterMM: Double) {
        self.innerDiameterMM = max(0.1, innerDiameterMM.isFinite ? innerDiameterMM : 16.5)
    }

    init(usSize: Double) {
        let size = usSize.isFinite ? usSize : 0
        self.init(innerDiameterMM: Self.diameterInterceptMM + Self.diameterPerUSSizeMM * size)
    }

    init(innerCircumferenceMM: Double) {
        let circumference = innerCircumferenceMM.isFinite ? innerCircumferenceMM : .pi * 16.5
        self.init(innerDiameterMM: circumference / .pi)
    }

    var innerCircumferenceMM: Double { .pi * innerDiameterMM }

    var innerRadiusMM: Double { innerDiameterMM * 0.5 }

    var usSize: Double {
        (innerDiameterMM - Self.diameterInterceptMM) / Self.diameterPerUSSizeMM
    }

    /// ISO 8653 sizes are inner circumferences in mm, so the exact ISO size is
    /// the circumference itself. The display label rounds to the whole
    /// millimetre jewellers quote.
    var isoCircumferenceMM: Double { innerCircumferenceMM }

    var isoLabel: String { String(format: "%.0f", innerCircumferenceMM) }

    static func < (lhs: FFRingSize, rhs: FFRingSize) -> Bool {
        lhs.innerDiameterMM < rhs.innerDiameterMM
    }
}

/// The snap increments the grid offers. They are discrete values rather than
/// an arbitrary double so the UI cannot invent a fourth increment silently.
enum FFGridStep: String, CaseIterable, Identifiable, Sendable {
    case tenth = "0.1"
    case half = "0.5"
    case whole = "1.0"

    var id: String { rawValue }

    var millimetres: Double {
        switch self {
        case .tenth: 0.1
        case .half: 0.5
        case .whole: 1.0
        }
    }

    var label: String { "\(rawValue) mm" }
}

/// Grid snapping in world space. Every coordinate is snapped independently so
/// a dragged point lands on a grid intersection, not just on a grid line.
enum FFGridSnap {
    static func snap(_ value: Double, to step: Double) -> Double {
        guard value.isFinite, step.isFinite, step > 0 else { return value }
        return (value / step).rounded() * step
    }

    static func snap(_ value: Double, to step: FFGridStep) -> Double {
        snap(value, to: step.millimetres)
    }

    static func snap(_ point: Vec3, to step: FFGridStep) -> Vec3 {
        Vec3(
            x: snap(point.x, to: step),
            y: snap(point.y, to: step),
            z: snap(point.z, to: step)
        )
    }
}

/// A scale bar the viewport can draw without another unit decision: the world
/// length, its on-screen width, and the human label all come from one plan.
struct FFScaleBarPlan: Equatable, Sendable {
    let lengthMM: Double
    let pixelWidth: Double
    let label: String
}

/// Chooses a 1-2-5 length close to the target pixel width. A scale bar that
/// changes width by more than 1.5x between zooms reads as a layout jump, so the
/// plan keeps the drawn bar near `targetWidth` at every zoom level.
enum FFScaleBar {
    static let targetWidth = 72.0

    static func plan(
        millimetresPerPoint: Double,
        targetWidth: Double = targetWidth,
        unit: FFLengthUnit = .millimetres
    ) -> FFScaleBarPlan? {
        guard millimetresPerPoint.isFinite, millimetresPerPoint > 0,
              targetWidth.isFinite, targetWidth > 0
        else { return nil }

        let idealLength = millimetresPerPoint * targetWidth
        let exponent = floor(log10(idealLength))
        let decade = pow(10, exponent)

        var bestLength = decade
        var bestDistance = Double.infinity
        for candidate in [decade, decade * 2, decade * 5, decade * 10] {
            let pixels = candidate / millimetresPerPoint
            let distance = abs(pixels - targetWidth)
            if distance < bestDistance {
                bestDistance = distance
                bestLength = candidate
            }
        }

        let pixelWidth = bestLength / millimetresPerPoint
        guard pixelWidth.isFinite, pixelWidth > 0 else { return nil }

        let decimals = bestLength < 1 ? 2 : (bestLength < 10 ? 1 : 0)
        return FFScaleBarPlan(
            lengthMM: bestLength,
            pixelWidth: pixelWidth,
            label: unit.formatted(millimetres: bestLength, decimals: decimals)
        )
    }
}
