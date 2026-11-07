import UIKit
import XCTest
@testable import FacetForge

/// Phase 24's arbitration proof. One hundred generated contact sequences drive
/// the same state machine the Metal viewport consults; only a one-finger
/// sequence may orbit, only a two-finger sequence may pan, and a palm, a Pencil
/// or a resting hand must produce no camera move at all.
final class Phase24TouchTests: XCTestCase {
    private enum Step {
        case down(Int, FFTouchKind)
        case up(Int)
        case sample(isIndirect: Bool, touchCount: Int)
    }

    private struct Scenario {
        let name: String
        let steps: [Step]
        let expectedCameraMoves: [FFCameraGestureIntent]
        let selectionChecks: [(FFTouchKind, Bool)]
    }

    func testOneHundredSyntheticSequencesProduceNoUnintendedCameraMoves() {
        let scenarios = Self.scenarios()
        XCTAssertEqual(scenarios.count, 100, "the row asks for exactly 100 sequences")

        var unintended: [String] = []
        var moveTotal = 0

        for scenario in scenarios {
            var arbitration = FFTouchArbitration()
            var moves: [FFCameraGestureIntent] = []

            for step in scenario.steps {
                switch step {
                case let .down(id, kind):
                    arbitration.begin(id: id, kind: kind)
                case let .up(id):
                    arbitration.end(id: id)
                case let .sample(isIndirect, touchCount):
                    let intent = arbitration.cameraIntent(
                        isIndirect: isIndirect,
                        touchCount: touchCount
                    )
                    moves.append(intent)
                }
            }

            XCTAssertEqual(
                arbitration.sequenceCount,
                1,
                "\(scenario.name): the generated touches must be one sequence"
            )
            XCTAssertEqual(
                moves,
                scenario.expectedCameraMoves,
                "\(scenario.name): camera intents"
            )

            let cameraMoves = moves.filter { $0 != .none }
            moveTotal += cameraMoves.count
            if scenario.expectedCameraMoves.isEmpty, !cameraMoves.isEmpty {
                unintended.append(scenario.name)
            }

            for (kind, expected) in scenario.selectionChecks {
                XCTAssertEqual(
                    arbitration.selectionAllowed(kind: kind),
                    expected,
                    "\(scenario.name): selection for \(kind.rawValue)"
                )
            }
        }

        XCTAssertTrue(
            unintended.isEmpty,
            "unintended camera moves in: \(unintended.joined(separator: ", "))"
        )
        XCTAssertGreaterThan(moveTotal, 0, "the suite never exercised a camera move")
    }

    func testPencilInterruptsAnInFlightFingerOrbit() {
        var arbitration = FFTouchArbitration()
        arbitration.begin(id: 1, kind: .finger)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: false, touchCount: 1), .orbit)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: false, touchCount: 1), .orbit)

        arbitration.begin(id: 2, kind: .pencil)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: false, touchCount: 2), .none)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: false, touchCount: 2), .none)

        arbitration.end(id: 2)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: false, touchCount: 1), .none)
        XCTAssertFalse(arbitration.selectionAllowed(kind: .finger))

        arbitration.end(id: 1)
        arbitration.begin(id: 3, kind: .finger)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: false, touchCount: 1), .orbit)
        XCTAssertEqual(arbitration.sequenceCount, 2)
    }

    func testThirdFingerDoesNotPan() {
        var arbitration = FFTouchArbitration()
        arbitration.begin(id: 1, kind: .finger)
        arbitration.begin(id: 2, kind: .finger)
        arbitration.begin(id: 3, kind: .finger)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: false, touchCount: 3), .none)
    }

    func testIndirectPointerPansWithoutTouchingTheCameraContacts() {
        var arbitration = FFTouchArbitration()
        arbitration.begin(id: 1, kind: .pencil)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: true, touchCount: 0), .pan)
        XCTAssertEqual(arbitration.cameraIntent(isIndirect: false, touchCount: 1), .none)
    }

    func testPalmClassificationUsesContactAreaAndPencilType() {
        XCTAssertEqual(FFTouchKind.classifyDirectContact(majorRadius: 10), .finger)
        XCTAssertEqual(
            FFTouchKind.classifyDirectContact(majorRadius: FFTouchKind.palmMajorRadius),
            .palm
        )
        XCTAssertEqual(FFTouchKind.classifyDirectContact(majorRadius: 70), .palm)
        XCTAssertEqual(
            FFTouchKind.classify(touchType: .pencil, majorRadius: 70),
            .pencil
        )
        XCTAssertEqual(
            FFTouchKind.classify(touchType: .indirect, majorRadius: 0),
            .finger
        )
        #if targetEnvironment(simulator)
        XCTAssertEqual(
            FFTouchKind.classify(touchType: .direct, majorRadius: 70),
            .finger,
            "the simulator has no real contact area"
        )
        #endif
    }

    func testSnapHapticsFireOncePerReachedDetent() {
        var driver = FFSnapHapticDriver()
        driver.begin(transform: .identity, step: 1)

        XCTAssertFalse(
            driver.update(transform: Mat4.translation(Vec3(x: 0.4, y: 0, z: 0)), step: 1),
            "a sub-step wobble must not buzz"
        )
        XCTAssertTrue(
            driver.update(transform: Mat4.translation(Vec3(x: 0.6, y: 0, z: 0)), step: 1)
        )
        XCTAssertFalse(
            driver.update(transform: Mat4.translation(Vec3(x: 1.2, y: 0, z: 0)), step: 1),
            "staying on the same detent must not repeat"
        )
        XCTAssertTrue(
            driver.update(transform: Mat4.translation(Vec3(x: 1.6, y: 0, z: 0)), step: 1)
        )

        driver.reset()
        driver.begin(
            transform: Mat4.translation(Vec3(x: 10, y: 0, z: 0)),
            step: 0.1
        )
        XCTAssertFalse(
            driver.update(
                transform: Mat4.translation(Vec3(x: 10.05, y: 0, z: 0)),
                step: 0.1
            ),
            "the 0.1 mm snap is below the haptic floor"
        )
    }

    func testProMotionPacingIsBoundedByThePanel() {
        XCTAssertEqual(FFDisplayPacing.preferredFramesPerSecond(maximumFramesPerSecond: nil), 60)
        XCTAssertEqual(FFDisplayPacing.preferredFramesPerSecond(maximumFramesPerSecond: 30), 60)
        XCTAssertEqual(FFDisplayPacing.preferredFramesPerSecond(maximumFramesPerSecond: 60), 60)
        XCTAssertEqual(FFDisplayPacing.preferredFramesPerSecond(maximumFramesPerSecond: 120), 120)
        XCTAssertEqual(FFDisplayPacing.preferredFramesPerSecond(maximumFramesPerSecond: 240), 120)
    }

    func testGizmoPlaneKeepsItsSmallPictureButNotASmallTarget() {
        XCTAssertGreaterThanOrEqual(FFGumballHitTarget.minimum, 44)
        XCTAssertEqual(FFGumballHitTarget.planeVisual, 24)
        XCTAssertGreaterThan(FFGumballHitTarget.minimum, FFGumballHitTarget.planeVisual)
    }

    // MARK: - Scenario generation

    private static func scenarios() -> [Scenario] {
        var result: [Scenario] = []

        for index in 0..<25 {
            let samples = 3 + (index % 5)
            result.append(
                Scenario(
                    name: "one-finger-\(index)",
                    steps: [.down(1, .finger)]
                        + Array(repeating: Step.sample(isIndirect: false, touchCount: 1), count: samples)
                        + [.up(1)],
                    expectedCameraMoves: Array(repeating: .orbit, count: samples),
                    selectionChecks: [(.finger, true)]
                )
            )
        }

        for index in 0..<25 {
            let samples = 3 + (index % 5)
            result.append(
                Scenario(
                    name: "two-finger-\(index)",
                    steps: [.down(1, .finger), .down(2, .finger)]
                        + Array(repeating: Step.sample(isIndirect: false, touchCount: 2), count: samples)
                        + [.up(1), .up(2)],
                    expectedCameraMoves: Array(repeating: .pan, count: samples),
                    selectionChecks: [(.finger, true)]
                )
            )
        }

        for index in 0..<15 {
            let samples = 2 + (index % 5)
            result.append(
                Scenario(
                    name: "palm-only-\(index)",
                    steps: [.down(1, .palm)]
                        + Array(repeating: Step.sample(isIndirect: false, touchCount: 1), count: samples)
                        + [.up(1)],
                    expectedCameraMoves: Array(repeating: .none, count: samples),
                    selectionChecks: [(.palm, false)]
                )
            )
        }

        for index in 0..<15 {
            let samples = 2 + (index % 4)
            let steps: [Step]
            if index.isMultiple(of: 2) {
                steps = [.down(1, .pencil), .down(2, .finger)]
                    + Array(repeating: Step.sample(isIndirect: false, touchCount: 2), count: samples)
                    + [.up(1), .up(2)]
            } else {
                steps = [.down(2, .finger), .down(1, .pencil)]
                    + Array(repeating: Step.sample(isIndirect: false, touchCount: 2), count: samples)
                    + [.up(2), .up(1)]
            }
            result.append(
                Scenario(
                    name: "pencil-and-resting-hand-\(index)",
                    steps: steps,
                    expectedCameraMoves: Array(repeating: .none, count: samples),
                    selectionChecks: [(.finger, false), (.pencil, true)]
                )
            )
        }

        for index in 0..<10 {
            let samples = 2 + (index % 4)
            result.append(
                Scenario(
                    name: "pencil-only-\(index)",
                    steps: [.down(1, .pencil)]
                        + Array(repeating: Step.sample(isIndirect: false, touchCount: 1), count: samples)
                        + [.up(1)],
                    expectedCameraMoves: Array(repeating: .none, count: samples),
                    selectionChecks: [(.pencil, true)]
                )
            )
        }

        for index in 0..<10 {
            let samples = 2 + (index % 4)
            let steps: [Step]
            if index.isMultiple(of: 2) {
                steps = [.down(1, .palm), .down(2, .finger)]
                    + Array(repeating: Step.sample(isIndirect: false, touchCount: 2), count: samples)
                    + [.up(1), .up(2)]
            } else {
                steps = [.down(2, .finger), .down(1, .palm)]
                    + Array(repeating: Step.sample(isIndirect: false, touchCount: 2), count: samples)
                    + [.up(2), .up(1)]
            }
            result.append(
                Scenario(
                    name: "finger-and-palm-\(index)",
                    steps: steps,
                    expectedCameraMoves: Array(repeating: .orbit, count: samples),
                    selectionChecks: [(.finger, true), (.palm, false)]
                )
            )
        }

        return result
    }
}
