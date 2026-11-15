import Foundation

/// Phase 56's committed thresholds.
///
/// The frame budget is the 60 fps budget the row names, and the pick budget is
/// the row's two milliseconds. They live in the shipping module, not in the
/// test, so a future change to the curve pipeline is measured against the same
/// numbers the row committed rather than against a number a test quietly
/// loosened.
enum FFCurvePerformanceBudget {
    /// The curve the row names: ten thousand control points.
    static let pointCount = 10_000
    /// One 60 fps frame.
    static let frameMilliseconds = 1_000.0 / 60.0
    /// One pick, in milliseconds.
    static let pickMilliseconds = 2.0
    /// Edits measured per benchmark. The fastest answer is the runner-relative
    /// figure, matching Phase 54's policy; the median is the noise guard.
    static let editSamples = 9
    /// Picks measured per benchmark, after the index is built.
    static let pickSamples = 200
}

/// One run of the committed harness: the curve size, the timings, and the
/// thresholds' own verdict. No Date or clock leaks into the values, so two
/// runs with the same timings compare equal.
struct FFCurveBenchmarkReport: Equatable, Sendable {
    let pointCount: Int
    let segmentCount: Int
    let renderedPointCount: Int
    /// Milliseconds per edit, in edit order; each includes the model edit, the
    /// incremental tessellation and the world-point projection.
    let editMilliseconds: [Double]
    /// Milliseconds per warm pick, in query order.
    let pickMilliseconds: [Double]
    let indexBuildMilliseconds: Double
    /// The linear picker's first few answers, for the record only. They are not
    /// gated: the row's threshold is the indexed pick, and a slower reference
    /// is evidence rather than a budget.
    let linearPickMilliseconds: [Double]

    var fastestEditMilliseconds: Double { editMilliseconds.min() ?? .infinity }
    var medianEditMilliseconds: Double { Self.median(editMilliseconds) }
    var medianPickMilliseconds: Double { Self.median(pickMilliseconds) }
    var pick95Milliseconds: Double { Self.percentile(pickMilliseconds, 0.95) }
    var fastestLinearPickMilliseconds: Double { linearPickMilliseconds.min() ?? .infinity }
    var medianLinearPickMilliseconds: Double { Self.median(linearPickMilliseconds) }

    var fastestEditMeetsBudget: Bool {
        fastestEditMilliseconds <= FFCurvePerformanceBudget.frameMilliseconds
    }

    /// The runner-noise guard: an edit must also be inside two frame budgets at
    /// the median, so a machine that is merely slow rather than noisy still
    /// fails.
    var medianEditMeetsBudget: Bool {
        medianEditMilliseconds <= FFCurvePerformanceBudget.frameMilliseconds * 2
    }

    var medianPickMeetsBudget: Bool {
        medianPickMilliseconds <= FFCurvePerformanceBudget.pickMilliseconds
    }

    var pick95MeetsBudget: Bool {
        pick95Milliseconds <= FFCurvePerformanceBudget.pickMilliseconds
    }

    var summary: String {
        let fastestEdit = String(format: "%.3f", fastestEditMilliseconds)
        let medianEdit = String(format: "%.3f", medianEditMilliseconds)
        let medianPick = String(format: "%.3f", medianPickMilliseconds)
        let p95Pick = String(format: "%.3f", pick95Milliseconds)
        let build = String(format: "%.3f", indexBuildMilliseconds)
        return "\(pointCount) points, \(segmentCount) segments, "
            + "\(renderedPointCount) rendered points; "
            + "edit fastest \(fastestEdit) ms, median \(medianEdit) ms "
            + "(budget \(String(format: "%.2f", FFCurvePerformanceBudget.frameMilliseconds)) ms); "
            + "pick median \(medianPick) ms, p95 \(p95Pick) ms "
            + "(budget \(String(format: "%.2f", FFCurvePerformanceBudget.pickMilliseconds)) ms); "
            + "index build \(build) ms"
    }

    static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        let clamped = FFMath.clamp(fraction, to: 0...1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}

/// The committed benchmark.
///
/// It builds one document with a ten-thousand-point curve, measures nine
/// single-control-point edits through the shipping render path (the model edit,
/// the incremental cache and the world-point projection), then measures warm
/// picks against an index over the projected curve. The index build is reported
/// separately because it happens on a camera change, not on every pick.
enum FFCurveBenchmark {
    /// A polyline payload with `pointCount` control points. Adjacent spans
    /// share their endpoints the way the line-chain tool writes them, so an
    /// edit to a joint is the ordinary case: it touches the two spans that
    /// meet there.
    static func polylinePayload(
        pointCount: Int = FFCurvePerformanceBudget.pointCount,
        spacing: Double = 0.0045,
        amplitude: Double = 8
    ) -> FFCurvePayload {
        guard pointCount >= 2 else {
            return FFCurvePayload(segments: [])
        }
        var points: [Vec2] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            points.append(Vec2(
                x: Double(index) * spacing,
                y: sin(Double(index) * 0.05) * amplitude
            ))
        }
        var segments: [FFCurveSegment] = []
        segments.reserveCapacity(pointCount - 1)
        for index in 0..<(pointCount - 1) {
            segments.append(FFCurveSegment(
                kind: .bezier,
                controlPoints: [FFPoint2(points[index]), FFPoint2(points[index + 1])]
            ))
        }
        return FFCurvePayload(segments: segments, isClosed: false)
    }

    static func document(
        name: String = "Phase 56 benchmark",
        nodeName: String = "Benchmark curve",
        payload: FFCurvePayload
    ) -> FFDocument {
        var document = FFDocument(name: name)
        document.rootNodes.append(FFNode(
            name: nodeName,
            geometry: .curve(payload),
            kind: .curve,
            layerID: document.currentLayerID
        ))
        return document
    }

    static func measure(pointCount: Int = FFCurvePerformanceBudget.pointCount) -> FFCurveBenchmarkReport {
        var payload = polylinePayload(pointCount: pointCount)
        var document = document(payload: payload)
        var caches: [UUID: FFCurveTessellationCache] = [:]

        // Prime the cache before the first sample; a cold build is a document
        // open, not an edit.
        _ = document.curveRenders(caches: &caches)

        var editSamples: [Double] = []
        editSamples.reserveCapacity(FFCurvePerformanceBudget.editSamples)
        for sample in 0..<FFCurvePerformanceBudget.editSamples {
            let segmentCount = payload.segments.count
            guard segmentCount > 0 else { break }
            let segmentIndex = (segmentCount / 2 + sample * 37) % segmentCount
            guard let lastPoint = payload.segments[segmentIndex].controlPoints.last else { continue }
            var target = lastPoint.vector
            target.y += 0.05 * Double(sample + 1)
            let reference = FFCurvePointRef(
                segment: segmentIndex,
                point: payload.segments[segmentIndex].controlPoints.count - 1
            )

            let began = DispatchTime.now().uptimeNanoseconds
            try? payload.moveControlPoint(reference, to: target)
            document.rootNodes[0].geometry = .curve(payload)
            _ = document.curveRenders(caches: &caches)
            let elapsed = DispatchTime.now().uptimeNanoseconds &- began
            editSamples.append(Double(elapsed) / 1_000_000)
        }

        let renders = document.curveRenders(caches: &caches)
        let renderedPointCount = renders.first?.worldPoints.count ?? 0
        let randomAccess = renderedPointCount > 0 ? Array(renders.first!.worldPoints) : []

        var camera = FFCamera.standard
        let bounds = AABB(
            minimum: Vec3(x: -1, y: -10, z: -1),
            maximum: Vec3(x: 46, y: 10, z: 1)
        )
        camera.frame(bounds: bounds, padding: 1.2)
        let viewport = Vec2(x: 1024, y: 768)

        let pickCurves = renders.map { render in
            FFPickCurve(
                id: render.id,
                name: render.name,
                points: render.worldPoints,
                isClosed: render.isClosed
            )
        }

        let buildBegan = DispatchTime.now().uptimeNanoseconds
        let index = FFCurveSpatialIndex(
            curves: pickCurves,
            camera: camera,
            viewport: viewport
        )
        let indexBuildMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds &- buildBegan
        ) / 1_000_000

        var pickSamples: [Double] = []
        var linearSamples: [Double] = []
        if let index, !randomAccess.isEmpty {
            let stride = max(1, randomAccess.count / FFCurvePerformanceBudget.pickSamples)
            var queryIndex = 0
            var offset = 0
            while queryIndex < randomAccess.count,
                  pickSamples.count < FFCurvePerformanceBudget.pickSamples {
                let query = camera.screenPoint(
                    for: randomAccess[queryIndex],
                    viewport: viewport
                )
                queryIndex += stride
                guard let query else { continue }
                // A point two screen points to the right of the curve is
                // inside the six-point tolerance on a straight span.
                let probe = Vec2(x: query.x + 2, y: query.y)

                if offset < 20 {
                    let linearBegan = DispatchTime.now().uptimeNanoseconds
                    _ = FFCurvePicker.pick(
                        curves: pickCurves,
                        at: probe,
                        camera: camera,
                        viewport: viewport
                    )
                    let linearElapsed = DispatchTime.now().uptimeNanoseconds &- linearBegan
                    linearSamples.append(Double(linearElapsed) / 1_000_000)
                }
                offset += 1

                let began = DispatchTime.now().uptimeNanoseconds
                _ = index.pick(at: probe)
                let elapsed = DispatchTime.now().uptimeNanoseconds &- began
                pickSamples.append(Double(elapsed) / 1_000_000)
            }
        }

        return FFCurveBenchmarkReport(
            pointCount: pointCount,
            segmentCount: payload.segments.count,
            renderedPointCount: renderedPointCount,
            editMilliseconds: editSamples,
            pickMilliseconds: pickSamples,
            indexBuildMilliseconds: indexBuildMilliseconds,
            linearPickMilliseconds: linearSamples
        )
    }
}
