import XCTest
@testable import FacetForge

/// Phase 30's proof: one documented table governs every displayed number, the
/// rounding utilities are idempotent and symmetric, and 10,000 chained
/// operations stay far inside the drift budget (one micrometre).
final class Phase30PrecisionTests: XCTestCase {
    // MARK: - The table

    func testDisplayTableMatchesTheDocumentedIncrements() {
        XCTAssertEqual(FFPrecision.lengthIncrementMM, 0.001, accuracy: 1e-15)
        XCTAssertEqual(FFPrecision.angleIncrementDegrees, 0.01, accuracy: 1e-15)
        XCTAssertEqual(FFPrecision.caratIncrement, 0.001, accuracy: 1e-15)

        // Decimals and increments cannot disagree: 10^-d must be the increment,
        // otherwise a string could print digits the policy does not own.
        XCTAssertEqual(
            pow(10, -Double(FFPrecision.lengthDecimalsMM)),
            FFPrecision.lengthIncrementMM,
            accuracy: 1e-15
        )
        XCTAssertEqual(
            pow(10, -Double(FFPrecision.angleDecimals)),
            FFPrecision.angleIncrementDegrees,
            accuracy: 1e-15
        )
        XCTAssertEqual(
            pow(10, -Double(FFPrecision.caratDecimals)),
            FFPrecision.caratIncrement,
            accuracy: 1e-15
        )

        // The inch table is chosen for resolution, not symmetry: five decimals
        // of an inch (0.000254 mm) stay finer than the millimetre increment,
        // where three would be 0.0254 mm and silently coarsen a value.
        let inchResolutionMM = pow(10, -Double(FFPrecision.lengthDecimalsInches)) * 25.4
        XCTAssertLessThan(inchResolutionMM, FFPrecision.lengthIncrementMM)
        XCTAssertEqual(FFPrecision.decimals(for: .millimetres), 3)
        XCTAssertEqual(FFPrecision.decimals(for: .inches), 5)
        XCTAssertEqual(FFPrecision.usRingSizeDecimals, 1)
    }

    func testEveryUserFacingLengthStringStaysInsideItsDigitBudget() {
        let lengths = [0.0, 0.0004, -0.0004, 1.23456, 18.0, 1234.56789, -9876.54321, 1_000_000]

        for value in lengths {
            let mm = FFPrecision.lengthString(millimetres: value, unit: .millimetres)
            XCTAssertTrue(mm.hasSuffix(" mm"), mm)
            XCTAssertEqual(FFPrecision.decimalDigitCount(in: mm), 3, "mm string '\(mm)' broke the 0.001 mm rule")
            let printedMM = Double(mm.replacingOccurrences(of: " mm", with: ""))
            XCTAssertNotNil(printedMM, mm)
            XCTAssertEqual(
                printedMM ?? .nan,
                FFPrecision.roundedLengthMM(value),
                accuracy: 1e-9,
                "mm string '\(mm)' is not the rounded value"
            )
            // Never a negative zero: "-0.000 mm" would read as a negative
            // measurement that does not exist.
            XCTAssertFalse(mm.hasPrefix("-0.000"), mm)

            let inches = FFPrecision.lengthString(millimetres: value, unit: .inches)
            XCTAssertTrue(inches.hasSuffix(" in"), inches)
            XCTAssertEqual(
                FFPrecision.decimalDigitCount(in: inches),
                FFPrecision.lengthDecimalsInches,
                "inch string '\(inches)' broke the five-decimal rule"
            )
            // Both strings describe the same rounded millimetre value, so the
            // unit switch cannot change the number, only its presentation.
            let printedInches = Double(inches.replacingOccurrences(of: " in", with: ""))
            XCTAssertNotNil(printedInches, inches)
            let inchesBackToMM = (printedInches ?? .nan) * 25.4
            XCTAssertEqual(
                inchesBackToMM,
                FFPrecision.roundedLengthMM(value),
                accuracy: inchResolutionMM,
                "inch string '\(inches)' lost the millimetre value"
            )
        }

        let angle = FFPrecision.angleString(degrees: 45.123456)
        XCTAssertEqual(angle, "45.12°")
        XCTAssertEqual(FFPrecision.decimalDigitCount(in: angle), 2)
        XCTAssertEqual(FFPrecision.angleString(degrees: 0), "0.00°")

        let carat = FFPrecision.caratString(carats: 1.23456)
        XCTAssertEqual(carat, "1.235 ct")
        XCTAssertEqual(FFPrecision.decimalDigitCount(in: carat), 3)
        XCTAssertEqual(FFPrecision.caratString(carats: 0.0004), "0.000 ct")
    }

    func testEveryFormattingPathUsesThePolicyRatherThanItsOwnDecimals() {
        // The measurement overlay is the widest user of the policy: all five
        // kinds, both units, must land inside the same table.
        let points = [
            FFMeasurementPoint(position: Vec3(x: 0, y: 0, z: 0)),
            FFMeasurementPoint(position: Vec3(x: 9, y: 0, z: 0)),
            FFMeasurementPoint(position: Vec3(x: 9, y: 9, z: 0)),
        ]

        for kind in FFMeasurementKind.allCases {
            let measurement = FFMeasurement(kind: kind, points: points)
            for unit in FFLengthUnit.allCases {
                let text = measurement.displayText(unit)
                if kind.isAngular {
                    XCTAssertTrue(text.hasSuffix("°"), text)
                    XCTAssertEqual(FFPrecision.decimalDigitCount(in: text), 2, text)
                } else {
                    XCTAssertEqual(
                        FFPrecision.decimalDigitCount(in: text),
                        FFPrecision.decimals(for: unit),
                        "\(kind.rawValue) text '\(text)' ignored the \(unit.rawValue) budget"
                    )
                }
            }
        }

        // The ring-size label is deliberately coarser than the length; it must
        // show exactly one decimal and never borrow the length budget.
        let ring = FFMeasurement(kind: .ringInnerDiameter, points: points)
        let ringText = ring.displayText(.millimetres)
        let usPart = ringText.components(separatedBy: "US ").last ?? ""
        XCTAssertEqual(FFPrecision.decimalDigitCount(in: usPart), 1, ringText)
    }

    // MARK: - Rounding utilities

    func testRoundingIsIdempotentSymmetricAndNormalisesZero() {
        let samples = [-9876.54321, -1.2345, -0.0004, 0, 0.0004, 1.2345, 18.0, 1_000_000]

        for value in samples {
            let once = FFPrecision.roundedLengthMM(value)
            XCTAssertEqual(FFPrecision.roundedLengthMM(once), once, accuracy: 0)
            XCTAssertEqual(
                FFPrecision.roundedLengthMM(-value),
                -once,
                accuracy: 1e-12,
                "rounding must be symmetric for \(value)"
            )
            let remainder = once.truncatingRemainder(dividingBy: FFPrecision.lengthIncrementMM)
            XCTAssertTrue(FFMath.isZero(remainder, tolerance: 1e-9), "\(once) is off the 0.001 mm grid")
        }

        // Half away from zero, so two values that differ only in sign round to
        // the same magnitude and a display never drifts between them.
        XCTAssertEqual(FFPrecision.roundedLengthMM(0.0005), 0.001, accuracy: 1e-12)
        XCTAssertEqual(FFPrecision.roundedLengthMM(-0.0005), -0.001, accuracy: 1e-12)

        // A guard, not a divide-by-zero: a bad increment leaves the value alone.
        XCTAssertEqual(FFPrecision.rounded(3.25, to: 0), 3.25)
        XCTAssertEqual(FFPrecision.rounded(3.25, to: -1), 3.25)
        XCTAssertTrue(FFPrecision.rounded(.nan, to: 0.001).isNaN)

        let negativeZero = FFPrecision.roundedLengthMM(-0.0004)
        XCTAssertEqual(negativeZero, 0, accuracy: 0)
        XCTAssertEqual(negativeZero.sign, .plus, "a rounded -0 would print '-0.000'")
    }

    // MARK: - Tolerances

    func testToleranceRegistryIsOrderedAndMatchesItsSubsystems() {
        // Each subsystem's tolerance names existing behaviour. They are
        // intentionally different: grouped from strictest to loosest, a value
        // that is coincident to the curve kernel need not be an intersection.
        let ordered = [
            FFTolerance.kernel,
            FFTolerance.curveJoin,
            FFTolerance.measurement,
            FFTolerance.snapping,
        ]
        XCTAssertEqual(ordered, ordered.sorted(), "tolerances must be ordered strictest first")
        for index in 1..<ordered.count {
            XCTAssertLessThan(ordered[index - 1], ordered[index])
        }
        XCTAssertEqual(FFTolerance.kernel, FFMath.eps)
        XCTAssertEqual(FFTolerance.driftBudget, 1e-6)
        XCTAssertLessThan(FFTolerance.driftBudget, FFPrecision.lengthIncrementMM)

        // Behavioural proof that the curve kernel reads the registry, not a
        // copied literal: 5e-8 mm apart is one point, 2e-7 mm apart is two.
        let first = Bezier2D([Vec2(x: 0, y: 0), Vec2(x: 1, y: 0)])!
        let touching = Bezier2D([Vec2(x: 1 + 5e-8, y: 0), Vec2(x: 2, y: 0)])!
        let apart = Bezier2D([Vec2(x: 1 + 2e-7, y: 0), Vec2(x: 2, y: 0)])!
        XCTAssertNotNil(Curve2D.bezier(first).joined(to: .bezier(touching)))
        XCTAssertNil(Curve2D.bezier(first).joined(to: .bezier(apart)))

        // The snapper's coincidence distance is looser than the curve join, so
        // an endpoint that joins is always an intersection candidate too.
        XCTAssertGreaterThan(FFTolerance.snapping, FFTolerance.curveJoin)
        // A displayed zero is a real measurement below one micrometre, which
        // is coarser than the snapper but finer than the display increment.
        XCTAssertLessThan(FFTolerance.measurement, FFPrecision.lengthIncrementMM)
    }

    // MARK: - Chained-operation drift

    func testTenThousandChainedLengthOperationsDriftUnderOneMicrometre() {
        // Three chains, each 10,000 operations, accumulated in Double and
        // compared with the closed form. The budget is one micrometre; the
        // display increment is one millimetre, so even the budget is 1000x
        // finer than a single step of any displayed value.
        let iterations = 10_000

        // 1. Linear accumulation of a one-millimetre move, the edit the gizmo
        //    performs when a finger drags a snap step.
        let start = Vec3(x: 0.1234, y: -0.5678, z: 9.8765)
        var position = start
        for _ in 0..<iterations {
            position = Vec3(
                x: position.x + 0.001,
                y: position.y - 0.0005,
                z: position.z + 0.00025
            )
        }
        let expected = Vec3(
            x: start.x + 0.001 * Double(iterations),
            y: start.y - 0.0005 * Double(iterations),
            z: start.z + 0.00025 * Double(iterations)
        )
        let linearDrift = (position - expected).length
        XCTAssertLessThan(linearDrift, FFTolerance.driftBudget, "linear chain drifted \(linearDrift) mm")

        // 2. Ten thousand 0.01° rotations, the angle policy's increment,
        //    compared against the direct 100° rotation. Rotating a point 10 mm
        //    from the pivot turns any angular error into a measurable mm.
        let point = Vec3(x: 10, y: 0, z: 0)
        var rotated = point
        for _ in 0..<iterations {
            rotated = Mat4.rotationZ(FFMath.radians(FFPrecision.angleIncrementDegrees))
                .transformedPoint(rotated)
        }
        let direct = Mat4.rotationZ(
            FFMath.radians(FFPrecision.angleIncrementDegrees * Double(iterations))
        ).transformedPoint(point)
        let rotationDrift = (rotated - direct).length
        XCTAssertLessThan(rotationDrift, FFTolerance.driftBudget, "rotation chain drifted \(rotationDrift) mm")

        // 3. A millimetre -> inch -> millimetre round trip on a growing value:
        //    the conversion is where a unit table could quietly lose digits.
        var millimetres = 1.0
        for _ in 0..<iterations {
            let inches = millimetres / 25.4
            millimetres = inches * 25.4 + 0.001
        }
        let expectedMillimetres = 1.0 + 0.001 * Double(iterations)
        let unitDrift = abs(millimetres - expectedMillimetres)
        XCTAssertLessThan(unitDrift, FFTolerance.driftBudget, "unit chain drifted \(unitDrift) mm")

        // And after all that chaining, the displayed value is still the one the
        // closed form displays: drift never becomes a visible jump.
        XCTAssertEqual(
            FFPrecision.lengthString(millimetres: millimetres, unit: .millimetres),
            FFPrecision.lengthString(millimetres: expectedMillimetres, unit: .millimetres)
        )
    }

    private var inchResolutionMM: Double {
        pow(10, -Double(FFPrecision.lengthDecimalsInches)) * 25.4
    }
}
