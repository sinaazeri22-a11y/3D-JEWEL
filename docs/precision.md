# Precision and units policy

Phase 30's rule set. One owner decides how a number is rounded and shown; every
subsystem reads that owner instead of choosing its own decimals.

- `FFPrecision` (`FacetForge/Units/FFPrecision.swift`) owns display increments,
  rounding, formatting and the per-subsystem tolerances (`FFTolerance`).
- `FFMeasurement` and `FFLengthUnit` call it; they do not format numbers
  themselves.

## What is stored, what is shown

Geometry, measurements and transforms are stored in **millimetres as `Double`**.
The visible unit is a presentation choice applied at the last moment, so
switching millimetres to inches never rewrites the document and never changes a
stored value. Angles are stored in degrees, stone weight in carats.

## Display table

| Quantity | Increment | Decimals | Screenshot/string example |
| --- | --- | --- | --- |
| Length, millimetres | 0.001 mm | 3 | `18.000 mm` |
| Length, inches | 0.00001 in (0.000254 mm) | 5 | `0.70866 in` |
| Angle | 0.01° | 2 | `135.00°` |
| Stone weight | 0.001 ct | 3 | `1.235 ct` |
| US ring size | 0.1 size | 1 | `US 7.8` |

Two rules hold the table together:

1. **Decimals and increments agree.** For millimetres, degrees and carats the
   increment is exactly `10^-decimals`. A string can therefore never show a
   digit the policy does not own.
2. **A unit switch cannot coarsen a value.** Five decimals of an inch resolve
   0.000254 mm, finer than the 0.001 mm millimetre step; three decimals would be
   0.0254 mm and would lose digits the millimetre view shows. The inch view is
   chosen for resolution, not for symmetry.

US ring size is a trade label, not a length. Jewellers quote it to a tenth of a
size, so it is deliberately coarser than the length policy and prints exactly
one decimal.

## Rounding

`FFPrecision.rounded(_:to:)` rounds to the nearest increment, **half away from
zero**, and normalises a negative zero to `+0` so a value never prints
`-0.000`.

- Idempotent: rounding an already rounded value returns it unchanged.
- Symmetric: `rounded(-x) == -rounded(x)`.
- Defensive: a zero, negative or non-finite increment leaves the value alone
  (it is a guard, not a divide-by-zero).
- Non-finite values format as zero rather than as `nan` or `inf`.

Formatting uses a POSIX locale (`en_US_POSIX`), so a copy-pasted value parses
with a dot on a device whose decimal separator is a comma. The unit suffix is
always printed (`mm`, `in`, `°`, `ct`) so a label in notes is unambiguous.

A length string rounds in millimetres **first**, then converts to the visible
unit. Both unit strings therefore describe the same rounded millimetre value and
differ only in presentation.

## Tolerances by subsystem

These are not interchangeable. A value that is coincident to the curve kernel
need not be an intersection to the snapper, and a measurement below its guard is
zero even though the geometry still exists.

| Subsystem | Constant | Value | Meaning |
| --- | --- | --- | --- |
| Kernel | `FFTolerance.kernel` | `FFMath.eps`, 1e-9 | relative normalisation/degeneracy guard |
| Curve join | `FFTolerance.curveJoin` | 1e-7 mm | endpoints closer than this are one point |
| Measurement | `FFTolerance.measurement` | 1e-6 mm | below one micrometre the interface reports zero |
| Snapper | `FFTolerance.snapping` | 1e-5 mm | coincidence distance when solving a screen constraint |
| Drift budget | `FFTolerance.driftBudget` | 1e-6 mm | test budget for 10,000 chained operations |

The constants are ordered strictest to loosest: kernel < curve join <
measurement < snapping. `FFTolerance.snapping` being looser than
`FFTolerance.curveJoin` means an endpoint that joins is always an intersection
candidate too.

Changing a constant changes the subsystem that owns it; the tests that exercise
that subsystem (`Phase16SnappingTests`, `CurveKernelTests`, `TessellationTests`,
`Phase19MeasurementTests`) are the proof that the named value is the live one.

## Drift proof

`Phase30PrecisionTests.testTenThousandChainedLengthOperationsDriftUnderOneMicrometre`
runs three 10,000-operation chains and compares each with its closed form:

1. a linear gizmo move accumulated in `Double` (0.001 mm, -0.0005 mm,
   0.00025 mm per step),
2. 10,000 rotations by the 0.01° angle increment applied to a point 10 mm from
   the pivot, compared with the direct 100° rotation,
3. a millimetre → inch → millimetre round trip on a growing value.

Each drift is asserted below `FFTolerance.driftBudget` (1e-6 mm). The budget is
1000x finer than the 0.001 mm display increment, so accumulated error can never
move a displayed value. The test also asserts that the drifted value and the
closed form format to the same string, which is the user-visible claim.

`FFPrecision.decimalDigitCount(in:)` exists for
`Phase30PrecisionTests.testEveryUserFacingLengthStringStaysInsideItsDigitBudget`
and the measurement-overlay test: they are the formatting table the phase row
names, and they walk both units and all five measurement kinds.

## Adding a new displayed quantity

1. Add its increment and decimals to `FFPrecision` with a comment saying why that
   resolution, not a rounder number.
2. Add a `*String` helper that rounds first, then formats through
   `FFPrecision.fixed`.
3. Add a row to the table above and a case to the digit-budget test.
4. If it needs a new subsystem tolerance, add it to `FFTolerance`, keep the
   strictest-to-loosest ordering, and say which test proves it is live.
