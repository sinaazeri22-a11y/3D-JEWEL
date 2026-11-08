import XCTest
import UIKit
@testable import FacetForge

/// Phase 19 acceptance: every kind measures its fixture to within 0.01 mm (or
/// 0.01° for the angle), labels stay at or above 9 pt and inside the viewport at
/// three zoom levels, and a tap only becomes a point through the Phase 16 snap
/// engine.
final class Phase19MeasurementTests: XCTestCase {
    /// The row's allowance. Every length assertion below also checks the exact
    /// value, so a regression that still fits the allowance but drifts from the
    /// fixture is caught by the tighter bound.
    private let allowance = 0.01

    // MARK: Fixtures

    /// A 3–4–5 triangle: the hypotenuse is exactly 5 mm and the right angle is
    /// exactly 90°, both independent of floating-point rounding.
    private var distanceFixture: [FFMeasurementPoint] {
        [
            FFMeasurementPoint(position: Vec3(x: 0, y: 0, z: 0)),
            FFMeasurementPoint(position: Vec3(x: 3, y: 4, z: 0))
        ]
    }

    private var angleFixture: [FFMeasurementPoint] {
        [
            FFMeasurementPoint(position: Vec3(x: 1, y: 0, z: 0)),
            FFMeasurementPoint(position: Vec3(x: 0, y: 0, z: 0)),
            FFMeasurementPoint(position: Vec3(x: 0, y: 1, z: 0))
        ]
    }

    /// Three points on a 9 mm circle in the XZ plane. The circumcircle is the
    /// fixture, so radius 9 and diameter 18 are known without a solver.
    private func circleFixture(radius: Double = 9) -> [FFMeasurementPoint] {
        let angles = [0.0, 2 * Double.pi / 3, 4 * Double.pi / 3]
        return angles.map { angle in
            FFMeasurementPoint(position: Vec3(
                x: radius * cos(angle),
                y: 0,
                z: radius * sin(angle)
            ))
        }
    }

    // MARK: Values against fixture truth

    func testDistanceMatchesFixtureTruth() throws {
        let measurement = FFMeasurement(kind: .distance, points: distanceFixture)
        let value = try XCTUnwrap(measurement.value)
        XCTAssertEqual(value, 5, accuracy: allowance)
        XCTAssertEqual(value, 5, accuracy: 1e-12)
        XCTAssertEqual(measurement.displayText(.millimetres), "5.000 mm")
    }

    func testAngleMatchesFixtureTruth() throws {
        let measurement = FFMeasurement(kind: .angle, points: angleFixture)
        let value = try XCTUnwrap(measurement.value)
        XCTAssertEqual(value, 90, accuracy: allowance)
        XCTAssertEqual(value, 90, accuracy: 1e-9)
        XCTAssertEqual(measurement.displayText(.millimetres), "90.00°")
    }

    func testRadiusMatchesFixtureTruth() throws {
        let measurement = FFMeasurement(kind: .radius, points: circleFixture())
        let value = try XCTUnwrap(measurement.value)
        XCTAssertEqual(value, 9, accuracy: allowance)
        XCTAssertEqual(value, 9, accuracy: 1e-9)
        XCTAssertEqual(measurement.displayText(.millimetres), "R 9.000 mm")
    }

    func testDiameterMatchesFixtureTruth() throws {
        let measurement = FFMeasurement(kind: .diameter, points: circleFixture())
        let value = try XCTUnwrap(measurement.value)
        XCTAssertEqual(value, 18, accuracy: allowance)
        XCTAssertEqual(value, 18, accuracy: 1e-9)
        XCTAssertEqual(measurement.displayText(.millimetres), "Ø 18.000 mm")
    }

    func testRingInnerDiameterMatchesFixtureTruthAndQuotesUSSize() throws {
        let measurement = FFMeasurement(kind: .ringInnerDiameter, points: circleFixture())
        let value = try XCTUnwrap(measurement.value)
        XCTAssertEqual(value, 18, accuracy: allowance)
        XCTAssertEqual(value, 18, accuracy: 1e-9)
        XCTAssertEqual(measurement.displayText(.millimetres), "Ø 18.000 mm · US 7.8")
    }

    /// Two snapped points at the same place measure 0 mm: that is a real value,
    /// not an error. A circle through three collinear points, by contrast, has
    /// no radius at all and must not print a number.
    func testZeroLengthIsAValueAndACollinearCircleIsNot() throws {
        let coincident = FFMeasurement(
            kind: .distance,
            points: [
                FFMeasurementPoint(position: .zero),
                FFMeasurementPoint(position: .zero)
            ]
        )
        XCTAssertEqual(try XCTUnwrap(coincident.value), 0, accuracy: allowance)
        XCTAssertEqual(coincident.displayText(.millimetres), "0.000 mm")

        let collinear = FFMeasurement(
            kind: .radius,
            points: [
                FFMeasurementPoint(position: Vec3(x: 0, y: 0, z: 0)),
                FFMeasurementPoint(position: Vec3(x: 1, y: 0, z: 0)),
                FFMeasurementPoint(position: Vec3(x: 2, y: 0, z: 0))
            ]
        )
        XCTAssertNil(collinear.value)
        XCTAssertEqual(collinear.displayText(.millimetres), "—")
    }

    // MARK: Unit-aware labels

    func testLabelsFollowTheDisplayUnit() {
        let distance = FFMeasurement(kind: .distance, points: distanceFixture)
        XCTAssertEqual(distance.displayText(.inches), "0.19685 in")

        let radius = FFMeasurement(kind: .radius, points: circleFixture())
        XCTAssertEqual(radius.displayText(.inches), "R 0.35433 in")

        let ring = FFMeasurement(kind: .ringInnerDiameter, points: circleFixture())
        XCTAssertEqual(ring.displayText(.inches), "Ø 0.70866 in · US 7.8")

        // An angle is not a length, so the unit switch cannot change it.
        let angle = FFMeasurement(kind: .angle, points: angleFixture)
        XCTAssertEqual(angle.displayText(.millimetres), angle.displayText(.inches))
    }

    // MARK: Label layout

    /// The row asks for labels at or above 9 pt and unclipped at three zoom
    /// levels. The camera moves, the text grows from the same value, and the
    /// rect must stay wholly inside the viewport each time.
    func testLabelsAreAtLeastNinePointsAndUnclippedAtThreeZoomLevels() throws {
        let viewport = Vec2(x: 1024, y: 768)
        let anchorPoint = Vec3(x: 9, y: 0, z: 0)
        let measurement = FFMeasurement(kind: .ringInnerDiameter, points: circleFixture())
        let text = measurement.displayText(.millimetres)

        var anchors: [String] = []
        for distance in [60.0, 150.0, 600.0] {
            let camera = FFCamera(distance: distance)
            let screen = try XCTUnwrap(camera.screenPoint(for: anchorPoint, viewport: viewport))
            let layout = try XCTUnwrap(
                FFMeasurementLabelLayout.label(text: text, anchor: screen, viewport: viewport)
            )

            XCTAssertGreaterThanOrEqual(layout.fontSize, FFMeasurementLabelLayout.minimumFontSize)
            XCTAssertGreaterThanOrEqual(layout.fontSize, 9)
            XCTAssertGreaterThanOrEqual(layout.rect.minX, 0)
            XCTAssertGreaterThanOrEqual(layout.rect.minY, 0)
            XCTAssertLessThanOrEqual(layout.rect.maxX, CGFloat(viewport.x))
            XCTAssertLessThanOrEqual(layout.rect.maxY, CGFloat(viewport.y))
            XCTAssertEqual(layout.text, text)

            anchors.append("\(Int(screen.x.rounded()))-\(Int(screen.y.rounded()))")
        }

        // The three zoom levels must actually project the anchor differently,
        // otherwise "at three zoom levels" would be three copies of one case.
        XCTAssertEqual(Set(anchors).count, 3)
    }

    /// The clamp is real, not incidental: an anchor far outside the viewport
    /// still yields a label wholly inside it.
    func testLabelClampsAnOffscreenAnchorInsideTheViewport() throws {
        let viewport = Vec2(x: 320, y: 240)
        let layout = try XCTUnwrap(FFMeasurementLabelLayout.label(
            text: "R 9.000 mm",
            anchor: Vec2(x: -4_000, y: -3_000),
            viewport: viewport
        ))
        XCTAssertGreaterThanOrEqual(layout.rect.minX, 0)
        XCTAssertGreaterThanOrEqual(layout.rect.minY, 0)
        XCTAssertLessThanOrEqual(layout.rect.maxX, CGFloat(viewport.x))
        XCTAssertLessThanOrEqual(layout.rect.maxY, CGFloat(viewport.y))
    }

    func testLabelIsRejectedByADegenerateViewport() {
        XCTAssertNil(FFMeasurementLabelLayout.label(
            text: "R 9.000 mm",
            anchor: .zero,
            viewport: .zero
        ))
    }

    // MARK: Snapped points

    /// A tap on a projected mesh vertex becomes that world vertex, with the snap
    /// kind that produced it. This is the row's "snapped measurement points"
    /// path, not an arithmetic-only shortcut.
    func testTapSnapsToAVertexOnVisibleGeometry() throws {
        let mesh = FFRenderMesh(
            positions: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 0, y: 0, z: 10)
            ],
            normals: [
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 0, y: 1, z: 0)
            ],
            indices: [0, 1, 2]
        )
        let node = FFRenderNode(name: "Fixture", mesh: mesh)
        let scene = FFViewportScene(nodes: [node])
        let camera = FFCamera(
            target: Vec3(x: 3, y: 0, z: 3),
            distance: 40,
            projection: .orthographic
        )
        let viewport = Vec2(x: 800, y: 600)
        let vertex = Vec3(x: 10, y: 0, z: 0)
        let screen = try XCTUnwrap(camera.screenPoint(for: vertex, viewport: viewport))

        let snapped = try XCTUnwrap(FFMeasurementSnap.point(
            at: screen,
            scene: scene,
            camera: camera,
            viewport: viewport
        ))
        XCTAssertEqual(snapped.position.x, vertex.x, accuracy: 1e-6)
        XCTAssertEqual(snapped.position.y, vertex.y, accuracy: 1e-6)
        XCTAssertEqual(snapped.position.z, vertex.z, accuracy: 1e-6)
        XCTAssertNotNil(snapped.snap)
        XCTAssertNotEqual(snapped.snap, .grid)
    }

    func testHiddenGeometryDoesNotSupplyMeasurementPoints() {
        let mesh = FFRenderMesh(
            positions: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 0, y: 0, z: 10)
            ],
            normals: [
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 0, y: 1, z: 0)
            ],
            indices: [0, 1, 2]
        )
        var node = FFRenderNode(name: "Fixture", mesh: mesh)
        node.isVisible = false
        let geometry = FFSnapGeometry.features(
            of: FFViewportScene(nodes: [node]),
            selectedIDs: Set([node.id])
        )
        XCTAssertTrue(geometry.points.allSatisfy { $0.kind == .centre })
        XCTAssertTrue(geometry.segments.isEmpty)
    }

    func testDegenerateTapInputIsRejected() {
        XCTAssertNil(FFMeasurementSnap.point(
            at: Vec2(x: 10, y: 10),
            scene: .empty,
            camera: .standard,
            viewport: .zero
        ))
    }

    // MARK: Session behaviour

    func testSessionCommitsOnlyAfterTheKindsLastPoint() {
        let session = FFMeasurementSession()
        session.kind = .distance
        XCTAssertNil(session.add(FFSnapPoint(Vec3(x: 0, y: 0, z: 0), kind: .vertex)))
        XCTAssertEqual(session.draft.count, 1)
        XCTAssertNotNil(session.add(FFSnapPoint(Vec3(x: 3, y: 4, z: 0), kind: .vertex)))
        XCTAssertEqual(session.draft.count, 0)
        XCTAssertEqual(session.measurements.count, 1)
        XCTAssertEqual(session.latest?.displayText(.millimetres), "5.000 mm")
        XCTAssertEqual(session.latest?.points.compactMap(\.snap), [.vertex, .vertex])
    }

    func testChangingKindAbandonsAnUnfinishedDraftButKeepsCommittedWork() {
        let session = FFMeasurementSession()
        session.add(FFSnapPoint(.zero, kind: .vertex))
        session.add(FFSnapPoint(Vec3(x: 3, y: 4, z: 0), kind: .vertex))
        session.add(FFSnapPoint(Vec3(x: 0, y: 0, z: 0), kind: .vertex))
        XCTAssertEqual(session.draft.count, 1)

        session.select(.angle)
        XCTAssertEqual(session.draft.count, 0)
        XCTAssertEqual(session.measurements.count, 1)
        XCTAssertEqual(session.latest?.kind, .distance)
    }

    func testClearRemovesCommittedMeasurements() {
        let session = FFMeasurementSession()
        session.add(FFSnapPoint(.zero, kind: .vertex))
        session.add(FFSnapPoint(Vec3(x: 3, y: 4, z: 0), kind: .vertex))
        XCTAssertEqual(session.measurements.count, 1)
        session.clear()
        XCTAssertTrue(session.measurements.isEmpty)
        XCTAssertNil(session.latest)
    }
}
