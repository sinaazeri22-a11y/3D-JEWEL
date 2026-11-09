import Foundation
import XCTest
@testable import FacetForge

/// Phase 39's acceptance: twenty drawn chains match their typed dimensions
/// within 1e-6 mm, and closing a chain to its start produces one closed curve.
///
/// The tests drive `FFEditorSession`, not the draft type, because the row's
/// point is a working tool: a typed length must reach the document through the
/// same `perform` call as every other edit, so undo, the journal and autosave
/// see one ordinary step. Geometry is read back out of the saved document, not
/// from the tool's own bookkeeping, so a wrong payload cannot pass.
final class Phase39LineChainTests: XCTestCase {
    /// A deterministic generator. The twenty chains have to be reproducible in
    /// a CI log, so the "random" chains are a fixed sequence, not `Double.random`.
    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func double(in range: ClosedRange<Double>) -> Double {
            let unit = Double(next() >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }

        mutating func integer(in range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
    }

    private let store = FFDocumentStore()
    private let fileManager = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("facetforge-phase39-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func curvePayloads(in document: FFDocument) -> [FFCurvePayload] {
        document.rootNodes.compactMap { $0.geometry?.curve }
    }

    /// The control points of one segment are its endpoints, so the segment's
    /// stored length is the distance between them. This reads the file form,
    /// not the draft, which is what the row measures.
    private func segmentLengths(of payload: FFCurvePayload) -> [Double] {
        payload.segments.map { segment in
            guard let first = segment.controlPoints.first,
                  let last = segment.controlPoints.last
            else { return -1 }
            return first.vector.distance(to: last.vector)
        }
    }

    // MARK: - Twenty typed chains

    func testTwentyDrawnChainsMatchTypedDimensionsWithinOneMicrometre() throws {
        var generator = Generator(seed: 0x39_2026_11_09)
        let session = FFEditorSession(document: FFDocument(name: "Line chains"))
        var expected: [[Double]] = []

        for chainIndex in 0..<20 {
            let start = Vec2(
                x: generator.double(in: -80...80),
                y: generator.double(in: -80...80)
            )
            session.beginLineChain(at: start)
            let segmentCount = generator.integer(in: 2...8)
            var typed: [Double] = []
            var cursor = start

            for _ in 0..<segmentCount {
                let degrees = generator.double(in: 0.0...360.0)
                let radians = degrees * .pi / 180
                let direction = Vec2(x: cos(radians), y: sin(radians))
                // The pointer only sets the bearing; the typed number sets the
                // distance, so the probe is deliberately unrelated to it.
                session.previewLineChain(at: cursor + direction * 10)
                let millimetres = generator.double(in: 0.5...250)
                let text = String(format: "%.6f", millimetres)
                let parsed = try XCTUnwrap(Double(text))
                XCTAssertTrue(
                    session.typeLineChainLength(text, unit: .millimetres),
                    "chain \(chainIndex) refused the typed length \(text): \(session.lineToolMessage ?? "no message")"
                )
                typed.append(parsed)
                cursor = cursor + direction * parsed
            }

            XCTAssertTrue(
                session.finishLineChain(),
                "chain \(chainIndex) refused to finish: \(session.lineToolMessage ?? "no message")"
            )
            expected.append(typed)
        }

        let payloads = curvePayloads(in: session.document)
        XCTAssertEqual(payloads.count, 20)
        XCTAssertEqual(session.curveNodes.count, 20)

        var segmentTotal = 0
        for (chainIndex, payload) in payloads.enumerated() {
            let lengths = segmentLengths(of: payload)
            XCTAssertEqual(lengths.count, expected[chainIndex].count, "chain \(chainIndex)")
            XCTAssertFalse(payload.isClosed)
            for (segmentIndex, length) in lengths.enumerated() {
                XCTAssertEqual(
                    length,
                    expected[chainIndex][segmentIndex],
                    accuracy: 1e-6,
                    "chain \(chainIndex) segment \(segmentIndex)"
                )
                segmentTotal += 1
            }
        }
        XCTAssertGreaterThanOrEqual(segmentTotal, 40)
    }

    // MARK: - Typed length and pointer direction

    func testTypedLengthFollowsThePointerDirection() throws {
        let session = FFEditorSession(document: FFDocument(name: "Typed"))

        session.beginLineChain(at: Vec2(x: 0, y: 0))
        session.previewLineChain(at: Vec2(x: 10, y: 0))
        XCTAssertTrue(session.typeLineChainLength("12.5", unit: .millimetres))

        // Next segment heads north: the typed value goes north, not east.
        session.previewLineChain(at: Vec2(x: 12.5, y: 8))
        XCTAssertTrue(session.typeLineChainLength("1", unit: .inches))

        XCTAssertTrue(session.finishLineChain())
        let payload = try XCTUnwrap(curvePayloads(in: session.document).first)
        XCTAssertEqual(payload.segments.count, 2)

        let first = payload.segments[0].controlPoints
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].vector.x, 0, accuracy: 1e-12)
        XCTAssertEqual(first[0].vector.y, 0, accuracy: 1e-12)
        XCTAssertEqual(first[1].vector.x, 12.5, accuracy: 1e-12)
        XCTAssertEqual(first[1].vector.y, 0, accuracy: 1e-12)

        let second = payload.segments[1].controlPoints
        XCTAssertEqual(second[0].vector.x, 12.5, accuracy: 1e-12)
        XCTAssertEqual(second[0].vector.y, 0, accuracy: 1e-12)
        XCTAssertEqual(second[1].vector.x, 12.5, accuracy: 1e-9)
        XCTAssertEqual(second[1].vector.y, 25.4, accuracy: 1e-9)
    }

    // MARK: - Closing

    func testTappingTheFirstVertexClosesOneCurve() throws {
        let session = FFEditorSession(document: FFDocument(name: "Closed"))
        let camera = FFCamera.standard
        let viewport = Vec2(x: 820, y: 1180)
        let first = Vec2(x: 0, y: 0)

        session.tapLineChain(at: first)
        session.tapLineChain(at: Vec2(x: 20, y: 0))
        session.tapLineChain(at: Vec2(x: 20, y: 20))
        session.tapLineChain(at: Vec2(x: 0, y: 20))
        XCTAssertEqual(session.lineChainDraft.points.count, 4)

        // The viewport resolves a tap through `FFLineChainPlacement`; a tap on
        // the first vertex has to resolve to that exact stored point, or the
        // chain would need a duplicate vertex to close.
        let screen = try XCTUnwrap(camera.screenPoint(
            for: Vec3(x: first.x, y: first.y, z: 0),
            viewport: viewport
        ))
        let resolved = try XCTUnwrap(FFLineChainPlacement.point(
            at: screen,
            scene: .empty,
            camera: camera,
            viewport: viewport,
            draftPoints: session.lineChainDraft.points
        ))
        XCTAssertEqual(resolved, first)

        XCTAssertTrue(session.tapLineChain(at: resolved))
        XCTAssertTrue(session.lineChainDraft.isClosed)
        XCTAssertTrue(session.finishLineChain())

        let payloads = curvePayloads(in: session.document)
        XCTAssertEqual(payloads.count, 1)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertTrue(payload.isClosed)
        // Four vertices and the closing segment: one curve, not two.
        XCTAssertEqual(payload.segments.count, 4)
        let firstVertex = try XCTUnwrap(payload.segments.first?.controlPoints.first?.vector)
        XCTAssertEqual(firstVertex, first)

        let path = try XCTUnwrap(payload.path())
        XCTAssertTrue(path.isClosed())

        let render = try XCTUnwrap(session.curveNodes.first)
        XCTAssertTrue(render.isClosed)
        XCTAssertGreaterThan(render.worldPoints.count, payload.segments.count)
        XCTAssertEqual(render.layerID, session.currentLayerID)

        // One command, one undo step: the whole chain disappears together.
        XCTAssertTrue(session.undo())
        XCTAssertTrue(curvePayloads(in: session.document).isEmpty)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(curvePayloads(in: session.document).first, Optional(payload))
    }

    // MARK: - Refusals

    func testToolRefusesInvalidInputWithASentence() throws {
        let session = FFEditorSession(document: FFDocument(name: "Refusals"))

        XCTAssertFalse(session.typeLineChainLength("12", unit: .millimetres))
        XCTAssertTrue(session.lineToolMessage?.contains("Move the pointer") == true)

        XCTAssertFalse(session.typeLineChainLength("diameter", unit: .millimetres))
        XCTAssertTrue(session.lineToolMessage?.contains("is not a length") == true)

        session.beginLineChain(at: Vec2(x: 0, y: 0))
        session.previewLineChain(at: Vec2(x: 10, y: 0))
        XCTAssertFalse(session.typeLineChainLength("0", unit: .millimetres))
        XCTAssertTrue(session.lineToolMessage?.contains("greater than zero") == true)
        XCTAssertFalse(session.typeLineChainLength("-2.5", unit: .millimetres))
        XCTAssertTrue(session.lineToolMessage?.contains("greater than zero") == true)
        XCTAssertEqual(session.lineChainDraft.points.count, 1)

        // A second vertex on top of the first is a refusal, not a zero-length
        // segment hidden in the curve.
        session.previewLineChain(at: Vec2(x: 0, y: 0))
        session.addLineChainPoint(at: Vec2(x: 0, y: 0))
        XCTAssertTrue(session.lineToolMessage?.contains("previous vertex") == true)
        XCTAssertEqual(session.lineChainDraft.points.count, 1)

        // One vertex is not a chain.
        XCTAssertFalse(session.finishLineChain())
        XCTAssertTrue(session.lineToolMessage?.contains("at least two vertices") == true)
        XCTAssertTrue(curvePayloads(in: session.document).isEmpty)
        XCTAssertTrue(session.lineChainDraft.isActive)

        // A tap that misses both geometry and the plane says so.
        XCTAssertFalse(session.tapLineChain(at: nil))
        XCTAssertTrue(session.lineToolMessage?.contains("sketch plane") == true)

        // Two vertices make an open chain but cannot close.
        session.previewLineChain(at: Vec2(x: 10, y: 0))
        XCTAssertTrue(session.typeLineChainLength("10", unit: .millimetres))
        XCTAssertFalse(session.closeLineChain())
        XCTAssertTrue(session.lineToolMessage?.contains("at least three vertices") == true)
        XCTAssertTrue(session.finishLineChain())
        let payload = try XCTUnwrap(curvePayloads(in: session.document).first)
        XCTAssertFalse(payload.isClosed)
        XCTAssertEqual(payload.segments.count, 1)

        // The tool was consumed by the finish: no second node from stale state.
        XCTAssertFalse(session.finishLineChain())
        XCTAssertTrue(session.lineToolMessage?.contains("Start a chain") == true)
        XCTAssertEqual(curvePayloads(in: session.document).count, 1)
    }

    // MARK: - Visibility

    func testCurvesFollowLayerAndNodeVisibility() throws {
        let session = FFEditorSession(document: FFDocument(name: "Visibility"))
        session.beginLineChain(at: Vec2(x: 0, y: 0))
        session.previewLineChain(at: Vec2(x: 10, y: 0))
        session.typeLineChainLength("10", unit: .millimetres)
        XCTAssertTrue(session.finishLineChain())
        XCTAssertEqual(session.curveNodes.count, 1)

        // A hidden layer hides its curves exactly as it hides its meshes, so
        // the overlay and the object tree cannot disagree.
        let layerID = try XCTUnwrap(session.currentLayerID)
        XCTAssertTrue(session.setLayerVisible(layerID, isVisible: false))
        XCTAssertTrue(session.curveNodes.isEmpty)
        XCTAssertTrue(session.document.curveRenders().isEmpty)
        XCTAssertTrue(session.setLayerVisible(layerID, isVisible: true))
        XCTAssertEqual(session.curveNodes.count, 1)
    }

    // MARK: - Readout

    func testLiveReadoutReportsLengthAndNormalisedAngle() throws {
        let session = FFEditorSession(document: FFDocument(name: "Readout"))

        XCTAssertNil(session.lineChainReadout)
        session.beginLineChain(at: Vec2(x: 5, y: 5))
        XCTAssertNil(session.lineChainReadout)
        session.previewLineChain(at: Vec2(x: 5, y: 12))
        let readout = try XCTUnwrap(session.lineChainReadout)
        XCTAssertEqual(readout.lengthMM, 7, accuracy: 1e-12)
        XCTAssertEqual(readout.angleDegrees, 90, accuracy: 1e-9)

        // A bearing in the third quadrant reads as 225, never as -135.
        let southWest = FFLineSegmentMeasure(from: Vec2(x: 0, y: 0), to: Vec2(x: -3, y: -3))
        XCTAssertEqual(southWest.angleDegrees, 225, accuracy: 1e-9)
        XCTAssertEqual(southWest.lengthMM, Vec2(x: 3, y: 3).length, accuracy: 1e-12)
        XCTAssertTrue(session.lineToolMessage == nil)

        session.cancelLineChain()
        XCTAssertNil(session.lineChainReadout)
        XCTAssertTrue(session.lineChainDraft.points.isEmpty)
    }

    // MARK: - Save and reopen

    func testFinishedChainRoundTripsThroughABundle() throws {
        let session = FFEditorSession(document: FFDocument(name: "Round trip"))
        session.beginLineChain(at: Vec2(x: 1, y: 2))
        session.previewLineChain(at: Vec2(x: 11, y: 2))
        session.typeLineChainLength("10", unit: .millimetres)
        session.previewLineChain(at: Vec2(x: 11, y: 6))
        session.typeLineChainLength("4", unit: .millimetres)
        XCTAssertTrue(session.closeLineChain())
        XCTAssertTrue(session.finishLineChain())

        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Chain.ffp")
        try store.save(session.document, to: url)

        let loaded = try store.load(from: url)
        XCTAssertEqual(loaded.stateHash, session.document.stateHash)
        XCTAssertEqual(curvePayloads(in: loaded), curvePayloads(in: session.document))
        XCTAssertEqual(loaded.curveRenders(), session.document.curveRenders())

        let payload = try XCTUnwrap(curvePayloads(in: loaded).first)
        XCTAssertTrue(payload.isClosed)
        XCTAssertEqual(payload.segments.count, 3)
        let lengths = segmentLengths(of: payload)
        let expected = [10.0, 4.0, Vec2(x: 10, y: 4).length]
        XCTAssertEqual(lengths.count, expected.count)
        for (length, typed) in zip(lengths, expected) {
            XCTAssertEqual(length, typed, accuracy: 1e-6)
        }
    }
}
