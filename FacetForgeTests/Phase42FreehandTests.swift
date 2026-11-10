import Foundation
import XCTest
@testable import FacetForge

/// Phase 42's acceptance: a drawn curve passes within 0.2 mm of its sample
/// points at default smoothing, and simplification preserves shape within
/// 0.05 mm.
///
/// The strokes are deterministic and analytic — a circle of known radius with a
/// small sine ripple — so the fit is measured against the samples the pencil
/// actually left, not against a second fit. The session tests then read the
/// committed payload out of a real document, because the row's point is a
/// working pencil: one `perform` must be the only thing between a stroke and
/// the file.
final class Phase42FreehandTests: XCTestCase {
    private let store = FFDocumentStore()
    private let fileManager = FileManager.default

    /// A deterministic curved stroke: a partial circle with a bounded ripple.
    /// Every point is at a known distance from the circle, so the fidelity
    /// measurement has an analytic scale.
    private func stroke(
        radius: Double,
        sweep: Double,
        ripple: Double,
        sampleCount: Int = 80
    ) -> [Vec2] {
        let center = Vec2(x: 2.5, y: -4.25)
        return (0...sampleCount).map { index in
            let t = Double(index) / Double(sampleCount)
            let angle = sweep * t
            let drifted = radius + ripple * sin(t * Double.pi * 6)
            return Vec2(
                x: center.x + cos(angle) * drifted,
                y: center.y + sin(angle) * drifted
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase42-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func curvePayloads(in document: FFDocument) -> [FFCurvePayload] {
        document.rootNodes.compactMap { $0.geometry?.curve }
    }

    /// Stored control points are compared with a tolerance rather than by `==`:
    /// a save round trip is allowed to normalise the last bit of a double, and
    /// the geometry is what matters, not the bit pattern.
    private func assertSameGeometry(
        _ actual: FFCurvePayload?,
        _ expected: FFCurvePayload,
        accuracy: Double = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("payload is missing", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.segments.count, expected.segments.count, file: file, line: line)
        XCTAssertEqual(actual.isClosed, expected.isClosed, file: file, line: line)
        for (stored, wanted) in zip(actual.segments, expected.segments) {
            XCTAssertEqual(stored.kind, wanted.kind, file: file, line: line)
            XCTAssertEqual(stored.controlPoints.count, wanted.controlPoints.count, file: file, line: line)
            for (a, b) in zip(stored.controlPoints, wanted.controlPoints) {
                XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
                XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
            }
        }
    }

    // MARK: - Fit fidelity

    func testFifteenStrokesFitWithinPointTwoMillimetresAtDefaultSmoothing() throws {
        XCTAssertEqual(FFFreehandStroke.defaultSmoothing, 0.35)

        for index in 0..<15 {
            let samples = stroke(
                radius: 4 + Double(index) * 3.75,
                sweep: Double.pi * (0.6 + Double(index % 4) * 0.35),
                ripple: 0.35 + Double(index % 3) * 0.2
            )
            let fitted = FFFreehandStroke(samples: samples)
            let payload = try fitted.payload()

            XCTAssertFalse(payload.segments.isEmpty, "case \(index) produced no spans")
            XCTAssertFalse(payload.isClosed, "case \(index) invented a closed stroke")
            XCTAssertNotNil(payload.path(), "case \(index) spans do not join")
            XCTAssertGreaterThanOrEqual(payload.segments.count, 2, "case \(index) is not a curve")
            XCTAssertLessThanOrEqual(
                fitted.maximumFitError(of: payload),
                FFFreehandStroke.maximumFitError + 1e-9,
                "case \(index) misses the 0.2 mm fidelity budget"
            )
            XCTAssertTrue(
                payload.segments.allSatisfy { $0.kind == .nurbs && $0.degree == 3 },
                "case \(index) is not a cubic NURBS fit"
            )
        }
    }

    func testSimplifiedPolylineStaysWithinFiftyMicrometresOfEverySample() {
        for index in 0..<15 {
            let samples = stroke(
                radius: 6 + Double(index) * 2,
                sweep: Double.pi * (0.5 + Double(index % 5) * 0.2),
                ripple: 0.6,
                sampleCount: 120
            )
            let fitted = FFFreehandStroke(samples: samples)
            let simplified = fitted.simplifiedPoints()
            XCTAssertGreaterThanOrEqual(simplified.count, 2, "case \(index) lost its endpoints")
            XCTAssertLessThanOrEqual(
                simplified.count,
                samples.count,
                "case \(index) simplification added points"
            )
            XCTAssertEqual(simplified.first, samples.first, "case \(index) moved the start")
            XCTAssertEqual(simplified.last, samples.last, "case \(index) moved the end")

            for sample in samples {
                var nearest = Double.infinity
                for step in 0..<(simplified.count - 1) {
                    nearest = min(
                        nearest,
                        FFFreehandStroke.distance(
                            from: sample,
                            toSegment: simplified[step],
                            simplified[step + 1]
                        )
                    )
                }
                XCTAssertLessThanOrEqual(
                    nearest,
                    fitted.simplifyTolerance + 1e-9,
                    "case \(index) simplification moved the shape"
                )
            }
        }
    }

    func testSmoothingRelaxesInteriorPointsAndKeepsEndpoints() {
        let samples = stroke(radius: 10, sweep: .pi, ripple: 0, sampleCount: 12)
        let untouched = FFFreehandStroke.relaxed(samples, amount: 0)
        let relaxed = FFFreehandStroke.relaxed(samples, amount: 0.9)

        XCTAssertEqual(untouched, samples)
        XCTAssertEqual(relaxed.first, samples.first)
        XCTAssertEqual(relaxed.last, samples.last)
        let middle = samples.count / 2
        XCTAssertLessThan(
            relaxed[middle].distance(to: samples[middle]),
            0.2,
            "0.9 smoothing should move an interior point toward its neighbours"
        )

        // A strong smoothing control changes the committed geometry, so the
        // slider is not a decorative value.
        var smooth = FFFreehandStroke(samples: samples)
        smooth.smoothing = 0.9
        var crisp = smooth
        crisp.smoothing = 0
        let smoothedPayload = try? smooth.payload()
        let crispPayload = try? crisp.payload()
        XCTAssertNotNil(smoothedPayload)
        XCTAssertNotNil(crispPayload)
        XCTAssertNotEqual(smoothedPayload, crispPayload, "smoothing does not reach the fit")
    }

    /// The trunk gate found a real hole here: a sparse drag with a snapped
    /// excursion can defeat simplification and smoothing even after the tighter
    /// retries, because those retries only lower the tolerance. The exact final
    /// pass must interpolate every sample instead of refusing a stroke the user
    /// actually drew. This path is the shape that failed: thirteen samples,
    /// direction reversals and a long excursion, 72.4 mm of polyline.
    func testSparseIrregularStrokeFallsBackToExactInterpolation() throws {
        let samples: [Vec2] = [
            Vec2(x: 0, y: 0),
            Vec2(x: 10.326329369471436, y: -5.355146037862373),
            Vec2(x: 7.7900115174935305, y: -7.46010341943762),
            Vec2(x: 5.763883640527505, y: -9.130090554183115),
            Vec2(x: 1.6292676911597876, y: -11.964310815622726),
            Vec2(x: 4.552912361639343, y: -11.314622395057524),
            Vec2(x: 3.8548528375950113, y: -12.626147058779269),
            Vec2(x: 4.91734133715217, y: 1.515372071835193),
            Vec2(x: 5.751728169661602, y: -1.9770114362620195),
            Vec2(x: 7.207588590294934, y: -4.483542103926327),
            Vec2(x: 7.26657229086456, y: -4.761749360711795),
            Vec2(x: 21.935847367803756, y: -7.23749520214443),
            Vec2(x: 30.186920560315542, y: -12.060097631481996),
        ]
        let stroke = FFFreehandStroke(samples: samples)

        // The preference attempts alone miss the budget, which is why this
        // stroke is the regression case rather than another smooth arc.
        let reduced = stroke.simplifiedPoints()
        let preferred = FFFreehandStroke.fit(points: FFFreehandStroke.relaxed(reduced, amount: 0.7))
        XCTAssertGreaterThan(
            stroke.maximumFitError(of: preferred),
            FFFreehandStroke.maximumFitError
        )

        let payload = try stroke.payload()
        XCTAssertEqual(payload.segments.count, samples.count - 1, "the exact pass must keep every sample")
        XCTAssertLessThanOrEqual(
            stroke.maximumFitError(of: payload),
            FFFreehandStroke.maximumFitError + 1e-9
        )
        XCTAssertNotNil(payload.path())
    }

    // MARK: - Refusals

    func testAnIncompleteStrokeAndAnInvalidThresholdAreRefused() {
        XCTAssertThrowsError(try FFFreehandStroke(samples: []).payload()) { error in
            XCTAssertEqual(error as? FFFreehandError, .notEnoughPoints)
        }
        XCTAssertThrowsError(try FFFreehandStroke(samples: [Vec2(x: 1, y: 2)]).payload()) { error in
            XCTAssertEqual(error as? FFFreehandError, .notEnoughPoints)
        }
        var invalid = FFFreehandStroke(samples: [Vec2(x: 0, y: 0), Vec2(x: 1, y: 1)])
        invalid.simplifyTolerance = 0
        XCTAssertThrowsError(try invalid.payload()) { error in
            XCTAssertEqual(error as? FFFreehandError, .invalidSimplifyTolerance)
        }
        XCTAssertFalse(
            FFFreehandError.notEnoughPoints.errorDescription?.isEmpty ?? true,
            "a refusal must carry a sentence the panel can show"
        )
    }

    // MARK: - Session commit

    func testStrokeCommitsAsOneCurveNodeAndOneUndoRestoresTheDocument() throws {
        let session = FFEditorSession(document: FFDocument(name: "Freehand"))
        let samples = stroke(radius: 12, sweep: .pi * 1.2, ripple: 0.4, sampleCount: 60)
        let nodeCount = session.documentSession.document.rootNodes.count

        session.beginFreehand()
        for point in samples {
            XCTAssertTrue(session.appendFreehand(at: point), "a valid sample was refused")
        }
        XCTAssertEqual(session.freehandPointCount, samples.count)
        XCTAssertGreaterThan(session.freehandLength, 0)

        XCTAssertTrue(session.finishFreehand(), "the stroke did not commit")
        XCTAssertEqual(session.documentSession.document.rootNodes.count, nodeCount + 1)
        XCTAssertEqual(session.freehandPointCount, 0, "the draft survived the commit")
        XCTAssertTrue(session.documentSession.canUndo)

        let expected = try FFFreehandStroke(samples: samples).payload()
        assertSameGeometry(
            curvePayloads(in: session.documentSession.document).last,
            expected
        )

        let status = session.documentStatus
        XCTAssertTrue(status.contains("Freehand spline"), "status does not name the commit: \(status)")
        XCTAssertTrue(status.contains("\(samples.count) points"), "status lost the sample count: \(status)")
        XCTAssertTrue(status.contains("mm"), "status lost the unit: \(status)")

        XCTAssertTrue(session.undo(), "the commit is not one undo step")
        XCTAssertEqual(session.documentSession.document.rootNodes.count, nodeCount)
        XCTAssertFalse(session.documentSession.canUndo)
    }

    func testFinishWithoutAStrokeIsRefusedAndCommitsNothing() {
        let session = FFEditorSession(document: FFDocument(name: "Empty"))
        let nodeCount = session.documentSession.document.rootNodes.count
        XCTAssertFalse(session.finishFreehand())
        XCTAssertEqual(session.documentSession.document.rootNodes.count, nodeCount)
        XCTAssertFalse(session.documentSession.canUndo)
        XCTAssertEqual(
            session.freehandToolMessage,
            FFFreehandError.notEnoughPoints.errorDescription
        )

        XCTAssertFalse(session.appendFreehand(at: nil))
        XCTAssertEqual(
            session.freehandToolMessage,
            "That stroke meets neither geometry nor the sketch plane"
        )
    }

    func testSmoothingAndSimplifyControlsAreBoundedToolState() {
        let session = FFEditorSession(document: FFDocument(name: "Controls"))
        session.setFreehandSmoothing(4)
        XCTAssertEqual(session.freehandDraft.smoothing, FFFreehandStroke.smoothingLimit)
        session.setFreehandSmoothing(-2)
        XCTAssertEqual(session.freehandDraft.smoothing, 0)
        session.setFreehandSimplify(0)
        XCTAssertEqual(
            session.freehandDraft.simplifyTolerance,
            FFFreehandStroke.defaultSimplifyTolerance,
            "a zero threshold must be refused, not stored"
        )
        session.setFreehandSimplify(0.12)
        XCTAssertEqual(session.freehandDraft.simplifyTolerance, 0.12, accuracy: 1e-12)
        XCTAssertFalse(session.documentSession.canUndo, "tool controls must not create undo steps")
    }

    func testFitStillEditsThroughAReopenedDocument() throws {
        let session = FFEditorSession(document: FFDocument(name: "Round trip"))
        let samples = stroke(radius: 9, sweep: .pi, ripple: 0.3, sampleCount: 48)
        for point in samples {
            session.appendFreehand(at: point)
        }
        XCTAssertTrue(session.finishFreehand())

        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("Freehand.ffp", isDirectory: true)
        try session.save(to: url)
        try session.reopen(from: url)

        let reopened = curvePayloads(in: session.documentSession.document)
        XCTAssertEqual(reopened.count, 1)
        assertSameGeometry(
            reopened.first,
            try FFFreehandStroke(samples: samples).payload(),
            accuracy: 1e-9
        )
        XCTAssertNotNil(reopened.first?.path(), "the reopened spline does not rebuild")
    }
}
