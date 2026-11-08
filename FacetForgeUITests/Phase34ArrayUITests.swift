import XCTest

/// Phase 34's acceptance in the shipping hierarchy. The stone is duplicated
/// from the panel, the copy is selected and removed with one undo, and a radial
/// array is created with twelve members whose count is then edited to eleven
/// and back, proving the parameters stay live after creation.
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
        let inspector = element("shell.inspector", app)
        let stone = element("tree.row.Stone", app)

        XCTAssertTrue(reveal(stone, inspector: inspector), "the Stone row is missing")
        XCTAssertTrue(
            (stone.value as? String)?.contains("selected") == true,
            "the launch selection is not the stone; value='\(stone.value ?? "")'"
        )

        // Duplicate: the copy appears beside the stone, becomes the selection
        // and is removed by one undo.
        let duplicate = element("array.duplicate", app)
        XCTAssertTrue(reveal(duplicate, inspector: inspector), "the duplicate command is missing")
        XCTAssertTrue(duplicate.isEnabled, "a selected unlocked stone should be duplicateable")
        duplicate.tap()

        let copy = element("tree.row.Stone copy", app)
        XCTAssertTrue(copy.waitForExistence(timeout: 15), "the duplicated row did not appear")
        XCTAssertTrue(
            waitFor(timeout: 10, { ((copy.value as? String) ?? "").contains("selected") }),
            "the duplicate did not become the selection; value='\(copy.value ?? "")'"
        )
        XCTAssertTrue(
            ((copy.value as? String) ?? "").contains("level 1"),
            "the copy should sit beside the stone; value='\(copy.value ?? "")'"
        )

        let undo = element("shell.document.undo", app)
        XCTAssertTrue(undo.isHittable, "the undo control is missing")
        undo.tap()
        XCTAssertTrue(waitFor(timeout: 15, { !copy.exists }), "undo did not remove the duplicate")

        // Radial array: select the stone again and use the panel's default
        // twelve-member full circle.
        XCTAssertTrue(reveal(stone, inspector: inspector), "the Stone row is not reachable")
        stone.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { ((stone.value as? String) ?? "").contains("selected") }),
            "the stone could not be selected again"
        )

        let radial = element("array.radial", app)
        XCTAssertTrue(reveal(radial, inspector: inspector), "the radial command is missing")
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

        // Editing after creation: one decrement must rebuild eleven concrete
        // members, not merely update a readout.
        let summary = element("array.summary", app)
        XCTAssertTrue(reveal(summary, inspector: inspector), "the array parameters are missing")
        XCTAssertTrue(
            waitFor(timeout: 10, { summary.label.contains("12 items") }),
            "the array summary does not report twelve items; label='\(summary.label)'"
        )
        XCTAssertTrue(
            summary.label.contains("30.00° apart"),
            "a twelve-member full circle should report 30° spacing; label='\(summary.label)'"
        )

        let decrease = element("array.count.decrease", app)
        XCTAssertTrue(reveal(decrease, inspector: inspector), "the count control is missing")
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
        XCTAssertTrue(reveal(increase, inspector: inspector), "the count restore control is missing")
        increase.tap()
        XCTAssertTrue(
            waitFor(timeout: 15, {
                ((array.value as? String) ?? "").contains("12 children")
            }),
            "restoring the count did not rebuild twelve members; value='\(array.value ?? "")'"
        )

        XCTAssertTrue(reveal(array, inspector: inspector), "the array row is not reachable")
        array.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { ((array.value as? String) ?? "").contains("selected") }),
            "the array row could not be reselected"
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

    @MainActor
    private func reveal(_ element: XCUIElement, inspector: XCUIElement) -> Bool {
        if isHittable(element) { return true }
        for _ in 0..<10 {
            scroll(inspector, up: true)
            if isHittable(element) { return true }
        }
        for _ in 0..<16 {
            scroll(inspector, up: false)
            if isHittable(element) { return true }
        }
        let found = isHittable(element)
        if !found {
            // A failing reveal is expensive to diagnose from the run log alone,
            // so record the hierarchy and the screen the runner actually saw.
            let hierarchy = XCTAttachment(string: inspector.debugDescription)
            hierarchy.name = "phase34-inspector-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "phase34-reveal-failure"
            shot.lifetime = .keepAlways
            add(shot)
        }
        return found
    }

    /// Scrolls from the inspector's outer gutter instead of its centre. The
    /// object tree's rows own a high-priority long-press-drag, and a synthesized
    /// swipe in the middle of the scroll view lands on a row, where the scroll
    /// never starts; the gutter is the scroll view itself. This moves the view
    /// only and leaves every assertion about what it finds unchanged.
    @MainActor
    private func scroll(_ inspector: XCUIElement, up: Bool) {
        let x = 0.03
        let start = inspector.coordinate(
            withNormalizedOffset: CGVector(dx: x, dy: up ? 0.85 : 0.15)
        )
        let end = inspector.coordinate(
            withNormalizedOffset: CGVector(dx: x, dy: up ? 0.15 : 0.85)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
        settle()
    }

    @MainActor
    private func isHittable(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
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
