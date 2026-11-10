import Foundation
import XCTest
@testable import FacetForge

/// Phase 40's acceptance: all three constructions pass analytic tests of
/// centre, radius and endpoints on fifteen cases, and the fourth deliverable,
/// the fillet preview, is tangent to both legs.
///
/// The tests build arcs from known circles, so the expected centre, radius and
/// endpoints are independent of the construction under test. They then read
/// the committed payload back out of a real document rather than trusting the
/// draft's own bookkeeping.
final class Phase40ArcTests: XCTestCase {
    private let store = FFDocumentStore()
    private let fileManager = FileManager.default

    private func point(center: Vec2, radius: Double, degrees: Double) -> Vec2 {
        let radians = degrees * Double.pi / 180
        return center + Vec2(x: cos(radians), y: sin(radians)) * radius
    }

    private func assertPoint(
        _ actual: Vec2,
        _ expected: Vec2,
        accuracy: Double = 1e-9,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message(), file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message(), file: file, line: line)
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase40-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func curvePayloads(in document: FFDocument) -> [FFCurvePayload] {
        document.rootNodes.compactMap { $0.geometry?.curve }
    }

    // MARK: - Three-point construction

    func testThreePointConstructionsPassAnalyticChecksOnFifteenCases() throws {
        for index in 0..<15 {
            let center = Vec2(x: Double(index) * 6.5 - 42, y: Double(index) * 3.25 - 18)
            let radius = 3.5 + Double(index % 5) * 5.25
            let startDegrees = Double((index * 37) % 360)
            let sweepDegrees = (index % 2 == 0 ? 1.0 : -1.0) * (25 + Double(index) * 8)
            let start = point(center: center, radius: radius, degrees: startDegrees)
            let through = point(
                center: center,
                radius: radius,
                degrees: startDegrees + sweepDegrees / 2
            )
            let end = point(
                center: center,
                radius: radius,
                degrees: startDegrees + sweepDegrees
            )

            let arc = try FFArc2D.through(start, through, end)
            let expectedSweep = sweepDegrees * Double.pi / 180

            XCTAssertEqual(arc.center.x, center.x, accuracy: 1e-9, "case \(index) centre x")
            XCTAssertEqual(arc.center.y, center.y, accuracy: 1e-9, "case \(index) centre y")
            XCTAssertEqual(arc.radius, radius, accuracy: 1e-9, "case \(index) radius")
            XCTAssertEqual(arc.sweep, expectedSweep, accuracy: 1e-9, "case \(index) sweep")
            assertPoint(arc.start, start, "case \(index) start")
            assertPoint(arc.mid, through, "case \(index) through")
            assertPoint(arc.end, end, "case \(index) end")
        }
    }

    // MARK: - Centre, start, end

    func testCenterStartEndConstructionsPassAnalyticChecksOnFifteenCases() throws {
        for index in 0..<15 {
            let center = Vec2(x: Double(index) * 5.5 - 35, y: Double(index) * -4.25 + 22)
            let radius = 2.25 + Double(index % 4) * 6.5
            let startDegrees = Double((index * 41) % 360)
            let sweepDegrees = (index % 2 == 0 ? 1.0 : -1.0) * (15 + Double(index) * 9)
            let start = point(center: center, radius: radius, degrees: startDegrees)
            let end = point(
                center: center,
                radius: radius,
                degrees: startDegrees + sweepDegrees
            )

            let arc = try FFArc2D.centerStartEnd(center: center, start: start, end: end)
            let expectedSweep = sweepDegrees * Double.pi / 180

            XCTAssertEqual(arc.center.x, center.x, accuracy: 1e-9, "case \(index) centre x")
            XCTAssertEqual(arc.center.y, center.y, accuracy: 1e-9, "case \(index) centre y")
            XCTAssertEqual(arc.radius, radius, accuracy: 1e-9, "case \(index) radius")
            XCTAssertEqual(arc.sweep, expectedSweep, accuracy: 1e-9, "case \(index) sweep")
            assertPoint(arc.start, start, "case \(index) start")
            assertPoint(arc.end, end, "case \(index) end")
        }
    }

    func testCenterStartEndProjectsTheEndBearingOntoTheCircle() throws {
        let center = Vec2(x: -4, y: 9)
        let radius = 12.5
        let start = point(center: center, radius: radius, degrees: 20)
        let offCircle = point(center: center, radius: radius * 1.08, degrees: 105)

        let arc = try FFArc2D.centerStartEnd(center: center, start: start, end: offCircle)

        XCTAssertEqual(arc.radius, radius, accuracy: 1e-12)
        XCTAssertEqual((arc.end - center).length, radius, accuracy: 1e-12)
        let expectedEnd = point(center: center, radius: radius, degrees: 105)
        assertPoint(arc.end, expectedEnd, accuracy: 1e-9)
        XCTAssertEqual(arc.sweep, 85 * Double.pi / 180, accuracy: 1e-9)
    }

    // MARK: - Tangent construction

    func testTangentConstructionsPassAnalyticChecksOnFifteenCases() throws {
        for index in 0..<15 {
            let start = Vec2(x: Double(index) * 4.25 - 30, y: Double(index) * -3.5 + 14)
            let tangentDegrees = Double((index * 29) % 360)
            let radians = tangentDegrees * Double.pi / 180
            let tangent = Vec2(x: cos(radians), y: sin(radians))
            let radius = 1.75 + Double(index % 6) * 3.5
            let normal = Vec2(x: -tangent.y, y: tangent.x)
            let center = start + normal * radius
            let startAngle = atan2(start.y - center.y, start.x - center.x)
            let sweepDegrees = 12 + Double(index) * 10
            let endAngle = startAngle + sweepDegrees * Double.pi / 180
            let end = center + Vec2(x: cos(endAngle), y: sin(endAngle)) * radius

            let arc = try FFArc2D.tangent(start: start, tangent: tangent, end: end)
            let expectedSweep = sweepDegrees * Double.pi / 180

            XCTAssertEqual(arc.center.x, center.x, accuracy: 1e-9, "case \(index) centre x")
            XCTAssertEqual(arc.center.y, center.y, accuracy: 1e-9, "case \(index) centre y")
            XCTAssertEqual(arc.radius, radius, accuracy: 1e-9, "case \(index) radius")
            XCTAssertEqual(arc.sweep, expectedSweep, accuracy: 1e-9, "case \(index) sweep")
            assertPoint(arc.start, start, "case \(index) start")
            assertPoint(arc.end, end, "case \(index) end")

            // The first derivative at the start must follow the supplied
            // tangent, not merely the tangent line in the opposite direction.
            let step = 1e-6
            let derivative = (arc.point(atFraction: step) - arc.start) / step
            let direction = try XCTUnwrap(derivative.normalized())
            XCTAssertEqual(direction.dot(tangent), 1, accuracy: 1e-6, "case \(index) tangent direction")
        }
    }

    // MARK: - Exact encoding

    func testEncodedArcsStayExactAndSplitAtNinetyDegrees() throws {
        let center = Vec2(x: 12, y: -7)
        let radius = 18.25
        let startAngle = 0.35
        let sweeps = [30.0, 45.0, 90.0, 91.0, 179.0, 180.0, 269.0, 271.0, -270.0, 359.9, 360.0]

        for sweepDegrees in sweeps {
            let arc = try FFArc2D(
                center: center,
                radius: radius,
                startAngle: startAngle,
                sweep: sweepDegrees * Double.pi / 180
            )
            let payload = FFArcTool.payload(for: arc)
            let expectedCount = max(
                1,
                Int(ceil(abs(arc.sweep) / FFArcTool.maximumSegmentSweep - 1e-12))
            )

            XCTAssertEqual(payload.segments.count, expectedCount, "sweep \(sweepDegrees) segment count")
            XCTAssertEqual(payload.isClosed, abs(abs(sweepDegrees) - 360) <= 1e-9, "sweep \(sweepDegrees) closed")
            XCTAssertNotNil(payload.path(), "sweep \(sweepDegrees) path")

            for segment in payload.segments {
                XCTAssertEqual(segment.kind, .nurbs)
                XCTAssertEqual(segment.degree, 2)
                XCTAssertEqual(segment.controlPoints.count, 3)
                XCTAssertEqual(segment.weights.count, 3)
                XCTAssertGreaterThan(segment.weights[1], 0, "sweep \(sweepDegrees) weight")
                XCTAssertEqual(segment.knots, [0, 0, 0, 1, 1, 1])
                let curve = try XCTUnwrap(segment.curve)
                for step in 0...10 {
                    let sample = curve.point(at: Double(step) / 10)
                    XCTAssertEqual(
                        (sample - center).length,
                        radius,
                        accuracy: 1e-9,
                        "sweep \(sweepDegrees) sample \(step)"
                    )
                }
            }

            let first = try XCTUnwrap(payload.segments.first?.controlPoints.first?.vector)
            let last = try XCTUnwrap(payload.segments.last?.controlPoints.last?.vector)
            assertPoint(first, arc.start, "sweep \(sweepDegrees) payload start")
            assertPoint(last, arc.end, "sweep \(sweepDegrees) payload end")

            let data = try JSONEncoder().encode(payload)
            let decoded = try JSONDecoder().decode(FFCurvePayload.self, from: data)
            XCTAssertEqual(decoded, payload)
        }
    }

    // MARK: - Fillet preview

    func testFilletPreviewIsTangentAndBoundedByBothLegs() throws {
        let corner = Vec2(x: 8, y: -3)

        for angleDegrees in [60.0, 90.0, 120.0] {
            for radius in [1.5, 4.0, 9.0] {
                let radians = angleDegrees * Double.pi / 180
                let first = corner + Vec2(x: 100, y: 0)
                let second = corner + Vec2(x: cos(radians), y: sin(radians)) * 100
                let arc = try FFArc2D.fillet(
                    corner: corner,
                    first: first,
                    second: second,
                    radius: radius
                )

                let firstDirection = try XCTUnwrap((first - corner).normalized())
                let secondDirection = try XCTUnwrap((second - corner).normalized())
                let tangentDistance = radius / tan(radians / 2)
                let toCenter = arc.center - corner

                XCTAssertEqual(arc.radius, radius, accuracy: 1e-9)
                XCTAssertEqual(abs(toCenter.cross(firstDirection)), radius, accuracy: 1e-9)
                XCTAssertEqual(abs(toCenter.cross(secondDirection)), radius, accuracy: 1e-9)
                XCTAssertEqual(
                    abs(arc.sweep),
                    Double.pi - radians,
                    accuracy: 1e-9,
                    "angle \(angleDegrees) radius \(radius) sweep"
                )
                assertPoint(
                    arc.start,
                    corner + firstDirection * tangentDistance,
                    "angle \(angleDegrees) radius \(radius) start"
                )
                assertPoint(
                    arc.end,
                    corner + secondDirection * tangentDistance,
                    "angle \(angleDegrees) radius \(radius) end"
                )
            }
        }

        XCTAssertThrowsError(try FFArc2D.fillet(
            corner: corner,
            first: corner + Vec2(x: 5, y: 0),
            second: corner + Vec2(x: 0, y: 5),
            radius: 50
        )) { error in
            XCTAssertEqual(error as? FFArcError, .filletExceedsLeg)
        }

        XCTAssertThrowsError(try FFArc2D.fillet(
            corner: corner,
            first: corner + Vec2(x: 10, y: 0),
            second: corner + Vec2(x: 20, y: 0),
            radius: 2
        )) { error in
            XCTAssertEqual(error as? FFArcError, .parallelLegs)
        }
    }

    // MARK: - Refusals

    func testArcRefusalsExplainThemselves() throws {
        XCTAssertThrowsError(try FFArc2D.through(
            Vec2(x: 0, y: 0),
            Vec2(x: 10, y: 0),
            Vec2(x: 20, y: 0)
        )) { error in
            XCTAssertEqual(error as? FFArcError, .collinearPoints)
        }

        XCTAssertThrowsError(try FFArc2D.through(
            Vec2(x: 0, y: 0),
            Vec2(x: 0, y: 0),
            Vec2(x: 20, y: 0)
        )) { error in
            XCTAssertEqual(error as? FFArcError, .coincidentPoints)
        }

        XCTAssertThrowsError(try FFArc2D.centerStartEnd(
            center: Vec2(x: 0, y: 0),
            start: Vec2(x: 1, y: 0),
            end: Vec2(x: 0, y: 0)
        )) { error in
            XCTAssertEqual(error as? FFArcError, .emptySweep)
        }

        XCTAssertThrowsError(try FFArc2D.tangent(
            start: Vec2(x: 0, y: 0),
            tangent: Vec2(x: 1, y: 0),
            end: Vec2(x: 5, y: 0)
        )) { error in
            XCTAssertEqual(error as? FFArcError, .noTangentCircle)
        }

        let session = FFEditorSession(document: FFDocument(name: "Refusals"))
        session.beginArc(mode: .threePoint)
        session.tapArc(at: Vec2(x: 0, y: 0))
        XCTAssertFalse(session.tapArc(at: Vec2(x: 0, y: 0)))
        XCTAssertTrue(session.arcToolMessage?.contains("distinct") == true)
        XCTAssertEqual(session.arcDraft.points.count, 1)

        session.tapArc(at: Vec2(x: 10, y: 0))
        XCTAssertFalse(session.tapArc(at: Vec2(x: 20, y: 0)))
        XCTAssertTrue(session.arcToolMessage?.contains("collinear") == true)
        XCTAssertEqual(session.arcDraft.points.count, 2)

        XCTAssertFalse(session.finishArc())
        XCTAssertTrue(session.arcToolMessage?.contains("three points") == true)
        XCTAssertTrue(curvePayloads(in: session.document).isEmpty)

        // The tool was consumed by Cancel: no stale draft can commit later.
        session.cancelArc()
        XCTAssertFalse(session.arcDraft.isActive)
        XCTAssertFalse(session.finishArc())
    }

    // MARK: - Commit, undo and save

    func testAllThreeConstructionsCommitAsOrdinaryCurves() throws {
        let session = FFEditorSession(document: FFDocument(name: "Arc commits"))
        let center = Vec2(x: 4, y: -6)
        let radius = 14.0

        session.beginArc(mode: .threePoint)
        session.tapArc(at: point(center: center, radius: radius, degrees: 10))
        session.tapArc(at: point(center: center, radius: radius, degrees: 55))
        XCTAssertTrue(session.tapArc(at: point(center: center, radius: radius, degrees: 100)))
        XCTAssertFalse(session.arcPreview.isEmpty)
        XCTAssertTrue(session.finishArc())

        session.beginArc(mode: .centerStartEnd)
        session.tapArc(at: center)
        session.tapArc(at: point(center: center, radius: radius, degrees: 10))
        XCTAssertTrue(session.tapArc(at: point(center: center, radius: radius, degrees: 100)))
        XCTAssertTrue(session.finishArc())

        session.beginArc(mode: .tangent)
        let tangentStart = point(center: center, radius: radius, degrees: 10)
        let tangentDirection = Vec2(
            x: -sin(10 * Double.pi / 180),
            y: cos(10 * Double.pi / 180)
        )
        session.tapArc(at: tangentStart)
        session.tapArc(at: tangentStart + tangentDirection * 5)
        XCTAssertTrue(session.tapArc(at: point(center: center, radius: radius, degrees: 100)))
        XCTAssertTrue(session.finishArc())

        XCTAssertEqual(session.curveNodes.count, 3)
        XCTAssertEqual(session.document.rootNodes.map(\.name), ["Arc", "Arc 2", "Arc 3"])
        XCTAssertEqual(curvePayloads(in: session.document).count, 3)

        for payload in curvePayloads(in: session.document) {
            let path = try XCTUnwrap(payload.path())
            XCTAssertFalse(path.curves.isEmpty)
        }

        // Each construction is one command: three undos remove all three.
        for expected in [2, 1, 0] {
            XCTAssertTrue(session.undo())
            XCTAssertEqual(session.curveNodes.count, expected)
        }
        XCTAssertFalse(session.undo())

        for expected in [1, 2, 3] {
            XCTAssertTrue(session.redo())
            XCTAssertEqual(session.curveNodes.count, expected)
        }
    }

    func testArcBundleRoundTripKeepsExactGeometry() throws {
        let session = FFEditorSession(document: FFDocument(name: "Arc round trip"))
        let center = Vec2(x: -9, y: 3)
        let radius = 21.75

        session.beginArc(mode: .threePoint)
        session.tapArc(at: point(center: center, radius: radius, degrees: 25))
        session.tapArc(at: point(center: center, radius: radius, degrees: 115))
        XCTAssertTrue(session.tapArc(at: point(center: center, radius: radius, degrees: 205)))
        XCTAssertTrue(session.finishArc())

        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Arc.ffp")
        try store.save(session.document, to: url)

        let loaded = try store.load(from: url)
        XCTAssertEqual(loaded.stateHash, session.document.stateHash)
        XCTAssertEqual(curvePayloads(in: loaded), curvePayloads(in: session.document))
        XCTAssertEqual(loaded.curveRenders(), session.document.curveRenders())

        let payload = try XCTUnwrap(curvePayloads(in: loaded).first)
        let arc = try FFArc2D.through(
            point(center: center, radius: radius, degrees: 25),
            point(center: center, radius: radius, degrees: 115),
            point(center: center, radius: radius, degrees: 205)
        )
        XCTAssertEqual(payload.segments, FFArcTool.payload(for: arc).segments)
        XCTAssertFalse(payload.isClosed)

        let path = try XCTUnwrap(payload.path())
        for curveSample in path.curves {
            for step in 0...8 {
                let sample = curveSample.point(at: Double(step) / 8)
                XCTAssertEqual((sample - center).length, radius, accuracy: 1e-9)
            }
        }
    }
}
