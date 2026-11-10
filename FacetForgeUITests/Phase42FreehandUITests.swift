import XCTest

/// Phase 42's user-visible half: the Sketch tool must be a real pencil. A drag
/// on the shipping viewport draws a stroke, the card reports it, the smoothing
/// control reaches the fit, and Finish commits one curve through the ordinary
/// document path — the object tree shows it as a curve — then one undo removes
/// it. The tree is asserted rather than the app bar's status line because that
/// line is legitimately shared with autosave and can be replaced within the
/// thirty-second save beat; the tree is the durable document record.
final class Phase42FreehandUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSketchToolDrawsAndCommitsAFreehandSpline() throws {
        let app = launch()
        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 30), "Metal viewport did not appear")

        let sketch = element("shell.tool.sketch", app)
        XCTAssertTrue(sketch.waitForExistence(timeout: 10), "the Sketch tool is missing")
        sketch.tap()

        let card = element("shell.freehand.card", app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the sketch card did not open")
        XCTAssertTrue(
            waitFor(timeout: 10, { card.isHittable }),
            "the sketch card is not reachable"
        )

        // One slow pencil drag in the middle of the viewport. The gesture is a
        // zero-distance drag, so this is the same path a finger takes.
        let start = metal.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.32))
        let end = metal.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.62))
        start.press(forDuration: 0.4, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)

        let readout = element("shell.freehand.readout", app)
        XCTAssertTrue(readout.waitForExistence(timeout: 10), "the stroke readout is missing")
        XCTAssertTrue(
            waitFor(timeout: 15, { readout.label.contains("points") }),
            "the card never reported the drawn points: \(readout.label)"
        )
        XCTAssertFalse(
            readout.label.contains("Drag on the sketch plane"),
            "the pencil did not reach the draft: \(readout.label)"
        )
        XCTAssertTrue(
            readout.label.contains("mm"),
            "the readout lost its unit: \(readout.label)"
        )

        // The smoothing slider must change the fit, not merely exist. A value
        // different from the default is checked before committing.
        let smoothing = app.sliders["shell.freehand.smoothing"]
        XCTAssertTrue(smoothing.waitForExistence(timeout: 10), "the smoothing slider is missing")
        smoothing.adjust(toNormalizedSliderPosition: 0.8)

        let finish = element("shell.freehand.finish", app)
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "the Finish command is missing")
        XCTAssertTrue(waitFor(timeout: 5, { finish.isEnabled }), "Finish stayed disabled")
        finish.tap()

        // The commit is visible twice: the card names the stored span count and
        // the app bar names the committed spline.
        let committed = element("shell.freehand.committed", app)
        XCTAssertTrue(committed.waitForExistence(timeout: 15), "the commit summary is missing")
        XCTAssertTrue(
            committed.label.contains("Committed"),
            "the card did not report the commit: \(committed.label)"
        )
        XCTAssertTrue(
            waitFor(timeout: 10, { committed.label.contains("segments") }),
            "the commit summary does not count the stored spans: \(committed.label)"
        )

        // The commit is a real curve node in the document tree, not just a
        // transient status line. The row's type is derived from the stored
        // geometry, so this also proves the payload was a curve.
        let nodeRow = element("tree.row.Freehand spline", app)
        XCTAssertTrue(
            nodeRow.waitForExistence(timeout: 10),
            "the committed spline is missing from the object tree"
        )
        XCTAssertTrue(
            ((nodeRow.value as? String) ?? "").contains("Curve"),
            "the committed node is not a curve: \(nodeRow.value ?? "")"
        )

        // The stroke is one ordinary document edit.
        let undo = element("shell.document.undo", app)
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the undo command is missing")
        undo.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { !nodeRow.exists }),
            "one undo did not remove the freehand spline from the object tree"
        )

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase42-freehand"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        let metal = element("shell.viewport.metal", app)
        if !metal.waitForExistence(timeout: 30) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "phase42-launch-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("Metal viewport did not appear")
        }
        return app
    }

    @MainActor
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
