import XCTest

/// Phase 34's acceptance in the shipping hierarchy. The launch stone is wrapped
/// in the panel's default twelve-member radial array; the summary must report a
/// 30° step, the count must rebuild eleven and then twelve concrete members, and
/// duplicating the array group must copy its parameters as one undo step. The
/// creation row and parameter card are pinned below the tree, so adding members
/// cannot push the controls away.
final class Phase34ArrayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDuplicateAndRadialArrayEditThroughThePanel() throws {
        let app = launch()

        // The fixture launches with the stone selected, which is what both the
        // array commands act on. The row itself may be below the fold while the
        // controls are pinned; its value is still asserted.
        let stone = element("tree.row.Stone", app)
        XCTAssertTrue(stone.waitForExistence(timeout: 15), "the Stone row is missing")
        XCTAssertTrue(
            (stone.value as? String)?.contains("selected") == true,
            "the launch selection is not the stone; value='\(stone.value ?? "")'"
        )

        // A radial array with the panel's default twelve members over 360°.
        let radial = element("array.radial", app)
        XCTAssertTrue(radial.waitForExistence(timeout: 10), "the radial command is missing")
        assertOnScreen(radial, "the radial command is not on screen", app: app)
        XCTAssertTrue(radial.isEnabled, "a selected unlocked stone should be arrayable")
        radial.tap()

        let array = element("tree.row.Stone Array", app)
        XCTAssertTrue(array.waitForExistence(timeout: 15), "the array group did not appear")
        XCTAssertTrue(
            waitFor(timeout: 10, { ((array.value as? String) ?? "").contains("12 children") }),
            "the array did not report twelve members; value='\(array.value ?? "")'"
        )
        XCTAssertTrue(
            waitFor(timeout: 10, { ((array.value as? String) ?? "").contains("selected") }),
            "the new array did not become the selection; value='\(array.value ?? "")'"
        )

        // The row's criterion: twelve members over 360° are exactly 30° apart,
        // and the parameters stay live after creation. A readout needs to be
        // present and correct, not tappable; the edits below are the controls
        // that must be reachable.
        let summary = element("array.summary", app)
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "the array parameters are missing")
        XCTAssertTrue(
            waitFor(timeout: 10, { summary.label.contains("12 items") }),
            "the array summary does not report twelve items; label='\(summary.label)'"
        )
        XCTAssertTrue(
            summary.label.contains("30.00° apart"),
            "a twelve-member full circle should report 30° spacing; label='\(summary.label)'"
        )

        // One decrement must rebuild eleven concrete members, not merely update
        // a readout.
        let decrease = element("array.count.decrease", app)
        assertOnScreen(decrease, "the count control is not on screen", app: app)
        decrease.tap()
        XCTAssertTrue(
            waitFor(timeout: 15, {
                ((array.value as? String) ?? "").contains("11 children")
            }),
            "editing the count did not rebuild eleven members; value='\(array.value ?? "")'"
        )
        XCTAssertTrue(
            waitFor(timeout: 10, { summary.label.contains("11 items") }),
            "the summary did not follow the count; label='\(summary.label)'"
        )

        let increase = element("array.count.increase", app)
        assertOnScreen(increase, "the count restore control is not on screen", app: app)
        increase.tap()
        XCTAssertTrue(
            waitFor(timeout: 15, {
                ((array.value as? String) ?? "").contains("12 children")
            }),
            "restoring the count did not rebuild twelve members; value='\(array.value ?? "")'"
        )

        // An array is a group like any other: duplicating the selected group
        // copies its parameters and every member, and one undo removes it.
        let duplicate = element("array.duplicate", app)
        assertOnScreen(duplicate, "the duplicate command is not on screen", app: app)
        XCTAssertTrue(duplicate.isEnabled, "the selected unlocked array should be duplicateable")
        duplicate.tap()

        let copy = element("tree.row.Stone Array copy", app)
        XCTAssertTrue(copy.waitForExistence(timeout: 15), "the duplicated array did not appear")
        XCTAssertTrue(
            waitFor(timeout: 10, { ((copy.value as? String) ?? "").contains("selected") }),
            "the duplicate did not become the selection; value='\(copy.value ?? "")'"
        )
        XCTAssertTrue(
            ((copy.value as? String) ?? "").contains("12 children"),
            "the duplicated array did not copy its members; value='\(copy.value ?? "")'"
        )
        XCTAssertTrue(
            ((copy.value as? String) ?? "").contains("level 1"),
            "the copy should sit beside the array; value='\(copy.value ?? "")'"
        )

        let undo = element("shell.document.undo", app)
        assertOnScreen(undo, "the undo control is missing", app: app)
        undo.tap()
        XCTAssertTrue(
            waitFor(timeout: 15, { !copy.exists }),
            "one undo did not remove the duplicated array"
        )

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase34-array-panel"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 30), "Metal viewport did not appear")
        return app
    }

    /// A control this test must press has to be on screen. Record the state
    /// before failing so a red run explains itself without another iteration.
    @MainActor
    private func assertOnScreen(
        _ element: XCUIElement,
        _ message: String,
        app: XCUIApplication
    ) {
        if element.exists && element.isHittable { return }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "phase34-failure-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase34-failure-screen"
        shot.lifetime = .keepAlways
        add(shot)
        XCTFail("\(message); exists=\(element.exists) hittable=\(element.isHittable)")
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
