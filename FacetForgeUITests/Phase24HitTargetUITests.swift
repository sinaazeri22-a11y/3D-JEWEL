import XCTest

/// Phase 24's two UI proofs: every visible control in the shipping hierarchy is
/// at least 44×44 pt, and after an orbit the X arrow still wins the drag it
/// visibly owns over the enlarged plane targets beneath it.
final class Phase24HitTargetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // The hierarchy audit walks ten element queries at each of seven
        // stages and every query is an accessibility snapshot, so a completed
        // audit costs 4-7 minutes on a loaded runner. The workflow's 240 s
        // default flagged a finished audit as a hang in run 42406979558, and
        // 480 s did the same in run 42572459983 while the audit was still
        // walking buttons at 477 s with ~2 s per query; the same code finished
        // the audit in 282 s in run 42569774037. The ceiling is a hang bound,
        // not a correctness gate, so it moves to 720 s while every assertion
        // and the 44 pt minimum stay exactly as they were.
        executionTimeAllowance = 720
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testEveryVisibleControlMeetsThe44PointMinimum() throws {
        let app = launch()
        var checked = 0

        checked += audit(app, stage: "launch")
        attach(app, "phase24-hit-targets-launch")

        let measure = element("shell.tool.measure", app)
        XCTAssertTrue(measure.waitForExistence(timeout: 10), "the Measure tool is missing")
        measure.tap()
        XCTAssertTrue(
            element("shell.measure.card", app).waitForExistence(timeout: 10),
            "the measurement card did not appear"
        )
        checked += audit(app, stage: "measure")
        attach(app, "phase24-hit-targets-measure")

        // The inspector is a ScrollView; audit each page rather than only the
        // controls that happen to be above the fold.
        let inspector = element("shell.inspector", app)
        XCTAssertTrue(inspector.waitForExistence(timeout: 10), "the inspector is missing")
        for page in 0..<4 {
            inspector.swipeUp()
            checked += audit(app, stage: "inspector-page-\(page)")
        }
        attach(app, "phase24-hit-targets-inspector")

        let gallery = element("shell.openGallery", app)
        XCTAssertTrue(gallery.waitForExistence(timeout: 10), "the gallery button is missing")
        gallery.tap()
        XCTAssertTrue(
            element("gallery.title", app).waitForExistence(timeout: 15),
            "the component gallery did not open"
        )
        checked += audit(app, stage: "gallery")
        attach(app, "phase24-hit-targets-gallery")

        XCTAssertGreaterThan(
            checked,
            40,
            "the audit found too few hittable controls to be a hierarchy check"
        )
    }

    @MainActor
    func testAxisArrowWinsOverTheEnlargedPlaneTargetAfterOrbit() throws {
        let app = launch()
        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 30), "Metal viewport did not appear")
        let readout = element("gumball.position", app)
        XCTAssertTrue(readout.waitForExistence(timeout: 30), "the gizmo did not appear")
        guard let before = parsePosition(readout.label) else {
            return XCTFail("could not read the initial gizmo position from '\(readout.label)'")
        }

        // This is the state that exposed Phase 23's hit-order defect: the plane
        // tiles and axis arrows can overlap after an orbit.
        let camera = element("shell.viewport.camera", app)
        XCTAssertTrue(camera.waitForExistence(timeout: 10), "camera HUD did not appear")
        let cameraBefore = camera.label
        let orbitStart = metal.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.74))
        let orbitEnd = metal.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.70))
        orbitStart.press(forDuration: 0.1, thenDragTo: orbitEnd)
        XCTAssertTrue(
            waitForCondition(timeout: 10, { camera.label != cameraBefore }),
            "orbit did not change the camera"
        )

        let pivot = element("gumball.pivot", app)
        let handle = element("gumball.handle.x", app)
        XCTAssertTrue(pivot.waitForExistence(timeout: 10), "gumball pivot is missing")
        XCTAssertTrue(handle.waitForExistence(timeout: 10), "gumball X handle is missing")

        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let pivotPoint = pivot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let toPivot = CGVector(
            dx: pivotPoint.screenPoint.x - start.screenPoint.x,
            dy: pivotPoint.screenPoint.y - start.screenPoint.y
        )
        XCTAssertGreaterThan(
            sqrt(toPivot.dx * toPivot.dx + toPivot.dy * toPivot.dy),
            8,
            "the X handle has no usable screen length"
        )
        let target = start.withOffset(
            CGVector(dx: toPivot.dx * 1.02, dy: toPivot.dy * 1.02)
        )
        start.press(forDuration: 0.15, thenDragTo: target)

        guard let after = waitForPosition(
            readout,
            timeout: 20,
            matching: { abs(abs($0.x - before.x) - 10) < 1e-3 }
        ) else {
            return XCTFail("the X arrow did not move 10 mm; readout is '\(readout.label)'")
        }
        XCTAssertEqual(abs(after.x - before.x), 10, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6, "the X drag moved Y")
        XCTAssertEqual(after.z, before.z, accuracy: 1e-6, "the X drag moved Z")

        attach(app, "phase24-axis-arrow-after-orbit")
    }

    // MARK: - Hierarchy audit

    @discardableResult
    @MainActor
    private func audit(_ app: XCUIApplication, stage: String) -> Int {
        var checked = 0
        var failures: [String] = []

        let queries: [(String, XCUIElementQuery)] = [
            ("button", app.buttons),
            ("textField", app.textFields),
            ("slider", app.sliders),
            ("switch", app.switches),
            ("segmentedControl", app.segmentedControls),
            ("picker", app.pickers),
            ("stepper", app.steppers),
            ("link", app.links),
            ("searchField", app.searchFields),
            ("textView", app.textViews),
        ]

        for (type, query) in queries {
            for element in query.allElementsBoundByIndex {
                // `exists` is another accessibility snapshot for the same
                // element and adds nothing: a missing element is not hittable
                // and its frame is empty, so the two guards below skip it. The
                // audit runs the same checks on the same controls with a third
                // fewer queries.
                guard element.isHittable else { continue }
                let frame = element.frame
                guard frame.width > 0, frame.height > 0 else { continue }
                checked += 1
                appendIfSmall(
                    element,
                    type: type,
                    frame: frame,
                    stage: stage,
                    failures: &failures
                )
            }
        }

        // Drag handles are accessible elements rather than buttons. Check the
        // gizmo targets explicitly so a 24 pt picture cannot hide a 24 pt
        // target.
        for identifier in [
            "gumball.handle.x",
            "gumball.handle.y",
            "gumball.handle.z",
            "gumball.plane.xy",
            "gumball.plane.yz",
            "gumball.plane.xz",
        ] {
            let element = app.descendants(matching: .any)[identifier]
            guard element.isHittable else { continue }
            let frame = element.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            checked += 1
            appendIfSmall(
                element,
                type: "gizmoHandle",
                frame: frame,
                stage: stage,
                failures: &failures
            )
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Phase 24 hit-target audit failed at \(stage):\n" + failures.joined(separator: "\n")
        )
        XCTAssertGreaterThan(
            checked,
            0,
            "Phase 24 hit-target audit found no hittable controls at \(stage)"
        )
        return checked
    }

    private func appendIfSmall(
        _ element: XCUIElement,
        type: String,
        frame: CGRect,
        stage: String,
        failures: inout [String]
    ) {
        let minimum: CGFloat = 44
        guard frame.width + 0.5 < minimum || frame.height + 0.5 < minimum else { return }
        let name = element.identifier.isEmpty ? element.label : element.identifier
        failures.append(
            "\(stage): \(type) '\(name)' is "
                + String(format: "%.1f×%.1f", frame.width, frame.height)
                + " pt (minimum 44×44)"
        )
    }

    // MARK: - Launch and helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        let viewport = element("shell.viewport", app)
        XCTAssertTrue(
            viewport.waitForExistence(timeout: 30),
            "shell viewport did not appear"
        )
        return app
    }

    private struct Position {
        var x: Double
        var y: Double
        var z: Double
    }

    private func parsePosition(_ label: String) -> Position? {
        let pattern = "([XYZ])\\s+(-?[0-9]+(?:\\.[0-9]+)?)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(label.startIndex..., in: label)
        var values: [String: Double] = [:]
        for match in expression.matches(in: label, range: range) {
            guard match.numberOfRanges == 3,
                  let axisRange = Range(match.range(at: 1), in: label),
                  let valueRange = Range(match.range(at: 2), in: label),
                  let value = Double(label[valueRange])
            else { continue }
            values[String(label[axisRange])] = value
        }
        guard let x = values["X"], let y = values["Y"], let z = values["Z"] else {
            return nil
        }
        return Position(x: x, y: y, z: z)
    }

    private func waitForPosition(
        _ element: XCUIElement,
        timeout: TimeInterval,
        matching predicate: (Position) -> Bool
    ) -> Position? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let position = parsePosition(element.label), predicate(position) {
                return position
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return parsePosition(element.label).flatMap { predicate($0) ? $0 : nil }
    }

    private func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    @MainActor
    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
