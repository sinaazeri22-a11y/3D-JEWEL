import XCTest

/// Phase 56's user-visible half. The row's numbers are measured by the unit
/// benchmark; what a UI test can prove is reachability: the ten-thousand-point
/// curve the harness measures is a real saved document, it opens through the
/// real reader, the overlay draws it, and the shell goes on answering gestures
/// and cards while it is on screen.
///
/// The timings here are freeze detectors, not budgets. Three orbits that take
/// tens of seconds, or a corner card that never appears, is the failure this
/// looks for; the 60 fps and 2 ms clauses are asserted in
/// `Phase56CurvePerformanceTests` against the committed thresholds.
final class Phase56CurvePerformanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTenThousandPointCurveDrawsAndTheShellStaysInteractive() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments.append("-FFCurvePerformanceFixture")
        app.launch()

        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(
            metal.waitForExistence(timeout: 60),
            "the viewport never opened the ten-thousand-point document"
        )
        XCTAssertTrue(waitFor(timeout: 30, { metal.isHittable }), "the Metal viewport is covered")

        // The saved curve is in the tree, as a curve. Selecting it comes after
        // the orbits so the gizmo a selection draws cannot sit under a gesture
        // the test is trying to attribute to the viewport.
        let row = element("tree.row.Benchmark curve", app)
        XCTAssertTrue(
            row.waitForExistence(timeout: 30),
            "the ten-thousand-point curve is missing from the object tree"
        )
        let kind = (row.value as? String) ?? ""
        XCTAssertTrue(kind.contains("Curve"), "the fixture row is not a curve: '\(kind)'")

        // Three orbit gestures across the curve. Each has to be taken by the
        // viewport and leave the shell able to answer the next query, which is
        // the shape of a frame loop that is still inside the gesture budget.
        let orbitsBegan = Date()
        for pass in 1...3 {
            let from = metal.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.56))
            let to = metal.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.5))
            from.press(
                forDuration: 0.05,
                thenDragTo: to,
                withVelocity: .slow,
                thenHoldForDuration: 0.1
            )
            XCTAssertTrue(
                waitFor(timeout: 20, { metal.isHittable }),
                "the viewport stopped being hittable after orbit \(pass)"
            )
            XCTAssertTrue(
                row.waitForExistence(timeout: 20),
                "the object tree stopped answering after orbit \(pass)"
            )
        }
        let orbitSeconds = Date().timeIntervalSince(orbitsBegan)
        XCTAssertLessThan(
            orbitSeconds,
            45,
            "three orbits took \(String(format: "%.1f", orbitSeconds)) s over the overlay"
        )

        // Selecting the curve is still not an edit.
        row.tap()
        let undo = element("shell.document.undo", app)
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the undo command is missing")
        XCTAssertFalse(undo.isEnabled, "opening and selecting the fixture created an undo step")

        // The corner card still opens over the curve, and closing it gives the
        // viewport back. That is the property the Phase 39 overlay was built to
        // keep and the one a heavier overlay is most likely to break.
        let toggle = element("shell.curves.toggle", app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the Curves chip is missing")
        toggle.tap()
        let card = element("shell.curves.card", app)
        XCTAssertTrue(
            card.waitForExistence(timeout: 20),
            "the curve card did not open over the ten-thousand-point overlay"
        )
        toggle.tap()
        XCTAssertTrue(
            waitFor(timeout: 20, { !card.exists }),
            "the curve card did not close"
        )
        XCTAssertTrue(
            waitFor(timeout: 20, { metal.isHittable }),
            "the viewport stayed covered after the card closed"
        )

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase56-ten-thousand-point-curve"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

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
