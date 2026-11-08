import Foundation

/// The one owner of display precision, rounding and the tolerance constants the
/// subsystems use.
///
/// Geometry is stored in millimetres as `Double`; nothing in the kernel depends
/// on the unit a person currently sees. This type only decides how a value is
/// rounded for display and how far apart two values may be before a subsystem
/// treats them as different.
///
/// The policy is documented in `docs/precision.md`, including why the inch
/// display carries five decimals (0.00001 in ≈ 0.000254 mm, finer than the
/// 0.001 mm length increment).
enum FFPrecision {
    // MARK: - Display increments

    /// The finest length difference the interface shows: one micrometre.
    static let lengthIncrementMM = 0.001
    static let lengthDecimalsMM = 3
    /// Five decimals of an inch stay finer than 0.001 mm; three would be
    /// 0.0254 mm and would silently coarsen a converted measurement.
    static let lengthDecimalsInches = 5

    /// The finest angle difference the interface shows: one hundredth of a
    /// degree.
    static let angleIncrementDegrees = 0.01
    static let angleDecimals = 2

    /// The finest carat difference the interface shows: one thousandth.
    static let caratIncrement = 0.001
    static let caratDecimals = 3

    /// US ring size is a trade label, not a length; jewellers quote it to a
    /// tenth of a size. It is deliberately coarser than the length policy.
    static let usRingSizeDecimals = 1

    // MARK: - Rounding

    /// Rounds to the nearest increment, half away from zero, and normalises
    /// negative zero so a display never reads "-0.000".
    static func rounded(_ value: Double, to increment: Double) -> Double {
        guard value.isFinite, increment.isFinite, increment > 0 else { return value }
        let rounded = (value / increment).rounded() * increment
        return rounded == 0 ? 0 : rounded
    }

    static func roundedLengthMM(_ millimetres: Double) -> Double {
        rounded(millimetres, to: lengthIncrementMM)
    }

    static func roundedAngleDegrees(_ degrees: Double) -> Double {
        rounded(degrees, to: angleIncrementDegrees)
    }

    static func roundedCarat(_ carats: Double) -> Double {
        rounded(carats, to: caratIncrement)
    }

    // MARK: - Formatting

    /// A fixed-decimal POSIX number. Using a locale-independent format is what
    /// keeps a copy-pasted value parseable on a device whose decimal separator
    /// is a comma.
    static func fixed(_ value: Double, decimals: Int) -> String {
        let places = max(0, decimals)
        // Normalise before formatting so a negative zero cannot print as
        // "-0.000", and a non-finite value has a defined spelling.
        let finite = value.isFinite && value != 0 ? value : 0
        return String(
            format: "%.\(places)f",
            locale: Locale(identifier: "en_US_POSIX"),
            finite
        )
    }

    static func decimals(for unit: FFLengthUnit) -> Int {
        unit == .inches ? lengthDecimalsInches : lengthDecimalsMM
    }

    /// A length rounded in millimetres, then converted and fixed to that unit's
    /// display precision.
    static func lengthString(millimetres: Double, unit: FFLengthUnit) -> String {
        let roundedMM = roundedLengthMM(millimetres)
        let converted = unit.value(fromMillimetres: roundedMM)
        return fixed(converted, decimals: decimals(for: unit)) + " " + unit.label
    }

    static func angleString(degrees: Double) -> String {
        fixed(roundedAngleDegrees(degrees), decimals: angleDecimals) + "°"
    }

    static func caratString(carats: Double) -> String {
        fixed(roundedCarat(carats), decimals: caratDecimals) + " ct"
    }

    /// The number of digits after the decimal point in a fixed string. The
    /// formatting tests use this to prove no path emits more digits than its
    /// policy allows.
    static func decimalDigitCount(in string: String) -> Int? {
        guard let dot = string.firstIndex(of: ".") else { return 0 }
        let fraction = string[string.index(after: dot)...]
            .prefix { $0.isNumber }
        return fraction.count
    }
}

/// Tolerances by subsystem. These are not interchangeable: a value that is
/// coincident to the snapper is not necessarily a valid kernel normal, and a
/// measurement below its guard is zero even though the geometry still exists.
///
/// The values name the existing behaviour rather than inventing a new one:
/// changing a constant here changes that subsystem, so each is covered by the
/// tests that already exercise it.
enum FFTolerance {
    /// Kernel normalisation and degeneracy guards, in relative units. This is
    /// the strictest threshold and predates the display policy.
    static let kernel = FFMath.eps

    /// Curve join/closed tests, in millimetres. Two endpoints closer than this
    /// are the same point to the curve kernel.
    static let curveJoin = 1e-7

    /// The snapper's coincidence distance, in millimetres. It is looser than
    /// the curve kernel because it solves a screen-space constraint.
    static let snapping = 1e-5

    /// A measurement below one micrometre is not a measurement the interface
    /// reports; it is zero.
    static let measurement = 1e-6

    /// The accepted drift after 10,000 chained operations, in millimetres.
    /// This is a test budget, not a geometry tolerance: one micrometre, which
    /// is 1000x finer than the 0.001 mm display increment, so accumulated
    /// error can never move a displayed value.
    static let driftBudget = 1e-6
}
