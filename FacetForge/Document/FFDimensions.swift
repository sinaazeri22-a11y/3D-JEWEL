import Foundation

/// What a stored dimension measures.
///
/// The three kinds are exactly the row's: a distance between two places, a
/// circle's radius, and the angle two spans meet at. They are named with the
/// same words Phase 52's constraints use, because a dimension that stopped
/// being expressible as a constraint would stop driving geometry.
enum FFDimensionKind: String, Codable, Sendable {
    case distance
    case radius
    case angle
}

/// What one dimension is attached to.
///
/// A distance names two ends; a radius names one circle; an angle names two
/// spans. Ends are anchors rather than bare indices so a dimension can start on
/// a point or on a circle's centre, which is the same vocabulary the solver
/// already understands.
enum FFDimensionTarget: Equatable, Sendable {
    case distance(from: FFSketchAnchor, to: FFSketchAnchor)
    case radius(circle: Int)
    case angle(first: Int, second: Int)
}

/// Why a dimension could not be added, edited or held.
///
/// Each case carries a sentence so a refusal explains itself rather than
/// silently doing nothing, which is the same rule Phases 44-52 follow.
enum FFDimensionError: Error, Equatable, LocalizedError {
    case unknownDimension
    case targetOutOfRange(String)
    case noPositiveValue(String)
    case angleOutOfRange(Double)
    case noBindingDimensions
    case unsatisfied(String)
    case notASketch

    var errorDescription: String? {
        switch self {
        case .unknownDimension:
            return "That dimension is not on this sketch"
        case .targetOutOfRange(let label):
            return "\(label) is not part of that sketch"
        case .noPositiveValue(let label):
            return "\(label) must be greater than zero"
        case .angleOutOfRange(let degrees):
            return "An angle of \(degrees)° is outside 0-90 degrees, the angle two lines meet at"
        case .noBindingDimensions:
            return "That sketch has no locked dimension to hold"
        case .unsatisfied(let label):
            return "That dimension over-constrains this sketch at: \(label)"
        case .notASketch:
            return "Select a sketch or a circle before dimensioning it"
        }
    }
}

/// One driving dimension on a sketch.
///
/// It is stored beside the payload, not inside it: the curve stays the ordinary
/// payload it was drawn as, and a document written before this field decodes
/// with no dimensions because the node's `dimensions` is optional. `value` is in
/// millimetres for a length and in degrees for an angle; the display unit is
/// applied when a readout asks for a sentence, never when the value is stored.
///
/// `first` and `second` carry indices whose meaning follows `kind`: a distance's
/// two ends (each a point, or a circle's centre when its flag is set), a radius's
/// circle in `first`, and an angle's two spans. The unused members stay at zero
/// so a record is a flat, stable JSON object with no optional fields of its own.
struct FFDimensionAnnotation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: FFDimensionKind
    var first: Int
    var second: Int
    var firstIsCentre: Bool
    var secondIsCentre: Bool
    /// Millimetres for a distance or a radius, degrees for an angle.
    var value: Double
    /// A locked dimension keeps its value whatever the geometry does; an
    /// unlocked one is a readout that follows the geometry.
    var isLocked: Bool

    init(
        id: UUID = UUID(),
        target: FFDimensionTarget,
        value: Double,
        isLocked: Bool = false
    ) {
        self.id = id
        self.value = value
        self.isLocked = isLocked
        switch target {
        case .distance(let from, let to):
            kind = .distance
            first = from.index
            firstIsCentre = from.isCentre
            second = to.index
            secondIsCentre = to.isCentre
        case .radius(let circle):
            kind = .radius
            first = circle
            firstIsCentre = false
            second = 0
            secondIsCentre = false
        case .angle(let firstSegment, let secondSegment):
            kind = .angle
            first = firstSegment
            firstIsCentre = false
            second = secondSegment
            secondIsCentre = false
        }
    }

    /// The target this record names, rebuilt from its own indices.
    var target: FFDimensionTarget {
        switch kind {
        case .distance:
            return .distance(
                from: firstIsCentre ? .circleCentre(first) : .point(first),
                to: secondIsCentre ? .circleCentre(second) : .point(second)
            )
        case .radius:
            return .radius(circle: first)
        case .angle:
            return .angle(first: first, second: second)
        }
    }

    /// The solver constraint this dimension stands for.
    ///
    /// One direction of translation only: a dimension becomes a constraint, so
    /// the scan through a sketch can never hold a number the solver was not
    /// given. The reverse is not claimed — a caller can constrain a sketch
    /// without storing a dimension for it.
    var constraint: FFSketchConstraint {
        switch target {
        case .distance(let from, let to):
            return .distance(from, to, value)
        case .radius(let circle):
            return .radius(circle: circle, value)
        case .angle(let firstSegment, let secondSegment):
            return .angle(first: firstSegment, second: secondSegment, value)
        }
    }

    /// Whether this dimension carries a length, which is what decides whether a
    /// solve keeps the uniform scale as a freedom.
    var isLengthDimension: Bool {
        kind != .angle
    }

    /// A display sentence in the document's unit.
    ///
    /// The stored value never changes with the unit: a 10 mm distance is
    /// `10.000 mm` or `0.39370 in`, both of which are the same millimetres. This
    /// is the row's unit-aware display, and it is a readout rather than a second
    /// stored number.
    func summary(unit: FFLengthUnit) -> String {
        switch kind {
        case .distance:
            return FFPrecision.lengthString(millimetres: value, unit: unit)
        case .radius:
            return "R " + FFPrecision.lengthString(millimetres: value, unit: unit)
        case .angle:
            return FFPrecision.angleString(degrees: value)
        }
    }

    /// What this dimension currently measures on a solved sketch.
    ///
    /// It is the same quantity the constraint compares against: a distance
    /// between the two anchored places, a circle's radius, or the angle the two
    /// lines meet at (folded into `0...90`, which is the convention Phase 52's
    /// `angle` constraint uses).
    func measured(in system: FFSketchSystem) throws -> Double {
        switch target {
        case .distance(let from, let to):
            guard let start = system.anchorPosition(from) else {
                throw FFDimensionError.targetOutOfRange(from.label)
            }
            guard let end = system.anchorPosition(to) else {
                throw FFDimensionError.targetOutOfRange(to.label)
            }
            return start.distance(to: end)
        case .radius(let circle):
            guard circle >= 0, circle < system.circles.count else {
                throw FFDimensionError.targetOutOfRange("Circle \(circle + 1)")
            }
            return system.circles[circle].radius
        case .angle(let firstSegment, let secondSegment):
            let x = system.flattened()
            let u = try system.direction(of: firstSegment, in: x).unit
            let v = try system.direction(of: secondSegment, in: x).unit
            let turn = atan2(u.cross(v), u.dot(v))
            let folded = FFSketchSystemSolver.foldAngle(FFSketchSystemSolver.wrapAngle(turn))
            return abs(folded) * 180 / .pi
        }
    }

    /// The same record with one value substituted, for a candidate solve.
    func withValue(_ newValue: Double) -> FFDimensionAnnotation {
        var copy = self
        copy.value = newValue
        return copy
    }
}

/// What one resolve produced.
///
/// `dimensions` is the record set after the solve: the binding dimensions keep
/// their typed values, and every readout has been re-measured on the solved
/// geometry, so a stored reference value and the shape it describes cannot
/// disagree.
struct FFDimensionResolution: Equatable, Sendable {
    var system: FFSketchSystem
    var dimensions: [FFDimensionAnnotation]
    var iterations: Int
    var residual: Double
    var degreesOfFreedom: Int
}

/// Holds a sketch to the dimensions that bind it.
///
/// The premise is stated here because it is the whole behaviour: every dimension
/// whose id is in `binding` is a hard row, and every other dimension is a
/// readout. A lock therefore means "keep this number whatever the geometry
/// does", while an unlocked dimension records what the geometry currently is.
/// Both go through Phase 52's solver rather than editing coordinates, which is
/// what makes a typed value arrive at the same answer as any other constraint
/// set and what keeps the freedom count honest.
enum FFSketchDimensionResolver {
    static func resolve(
        _ system: FFSketchSystem,
        dimensions: [FFDimensionAnnotation],
        binding: Set<UUID>
    ) throws -> FFDimensionResolution {
        let driving = dimensions.filter { binding.contains($0.id) }
        guard !driving.isEmpty else { throw FFDimensionError.noBindingDimensions }

        let solution = try FFSketchSystemSolver.solve(
            system,
            constraints: driving.map(\.constraint)
        )
        guard solution.isSatisfied else {
            let named = solution.conflicts.first?.label ?? "one of those dimensions"
            throw FFDimensionError.unsatisfied(named)
        }

        var updated: [FFDimensionAnnotation] = []
        updated.reserveCapacity(dimensions.count)
        for dimension in dimensions {
            if binding.contains(dimension.id) {
                updated.append(dimension)
            } else {
                var copy = dimension
                copy.value = try dimension.measured(in: solution.system)
                updated.append(copy)
            }
        }
        return FFDimensionResolution(
            system: solution.system,
            dimensions: updated,
            iterations: solution.iterations,
            residual: solution.residual,
            degreesOfFreedom: solution.degreesOfFreedom
        )
    }
}

extension FFDocument {
    /// This node's stored dimensions, or none when it is not dimensioned.
    func dimensionAnnotations(forNodeID target: UUID) -> [FFDimensionAnnotation] {
        node(withID: target)?.dimensions ?? []
    }

    /// Runs one pure edit against a node's dimension list. The document stays the
    /// only owner; an empty list writes nil so a document that never carried a
    /// dimension keeps the canonical hash it had before this phase existed.
    @discardableResult
    mutating func editDimensions(
        nodeID: UUID,
        _ edit: (inout [FFDimensionAnnotation]) throws -> Void
    ) throws -> Bool {
        guard let node = node(withID: nodeID) else { return false }
        var dimensions = node.dimensions ?? []
        try edit(&dimensions)
        return updateNode(withID: nodeID) {
            $0.dimensions = dimensions.isEmpty ? nil : dimensions
        }
    }
}
