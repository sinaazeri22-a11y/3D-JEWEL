import XCTest

/// Phase 31's panel acceptance. The set switcher and the four state controls are
/// all real taps: switching must restore that set's stored visibility/print and
/// never rewrite the other set, and the chip/row boundary must keep each target
/// answering only its own tap.
final class Phase31LayerSetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSetSwitchRestoresItsOwnStatesAndTemplateImportsLayers() throws {
        let app = launch()

        let stonesRow = element("layer.row.1", app)
        XCTAssertTrue(stonesRow.waitForExistence(timeout: 15), "the layer panel is missing")
        XCTAssertEqual(stonesRow.value as? String, "Visible")

        // Set A (Default): Stones hidden and Metal excluded from print.
        element("layer.visible.1", app).tap()
        waitForValue(stonesRow, "Hidden", "hiding Stones did not record the state")
        element("layer.print.0", app).tap()
        waitForValue(
            element("layer.print.0", app),
            "Does not print",
            "the print state was not recorded"
        )

        // Set B starts from what is on screen, then changes both states.
        element("layer.set.add", app).tap()
        waitForLabel(
            element("layer.set.current", app),
            "Set 2",
            "a new layer set was not activated"
        )
        element("layer.visible.1", app).tap()
        waitForValue(stonesRow, "Visible", "showing Stones did not record set B")
        element("layer.print.0", app).tap()
        waitForValue(
            element("layer.print.0", app),
            "Prints",
            "printing Metal did not record set B"
        )

        // Back to A: its hidden/not-print states return.
        element("layer.set.0", app).tap()
        waitForLabel(
            element("layer.set.current", app),
            "Default",
            "set A did not become active again"
        )
        waitForValue(stonesRow, "Hidden", "set A's hidden Stones did not return")
        waitForValue(
            element("layer.print.0", app),
            "Does not print",
            "set A's print state did not return"
        )

        // Back to B: A's switch must not have rewritten B.
        element("layer.set.1", app).tap()
        waitForValue(stonesRow, "Visible", "set B's visible Stones did not return")
        waitForValue(
            element("layer.print.0", app),
            "Prints",
            "set B's print state did not return"
        )

        let setShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        setShot.name = "phase31-layer-sets"
        setShot.lifetime = .keepAlways
        add(setShot)

        // Import the workshop document template. Only the three template layers
        // are new, and Annotations is non-printing by definition.
        element("layer.template", app).tap()
        let findings = element("layer.row.2", app)
        XCTAssertTrue(findings.waitForExistence(timeout: 10), "the template did not add a layer")
        XCTAssertTrue(findings.label.contains("Findings"), "row 2 was '\(findings.label)'")
        XCTAssertTrue(
            element("layer.row.3", app).label.contains("Annotations"),
            "the template layers did not append in order"
        )
        waitForValue(
            element("layer.print.3", app),
            "Does not print",
            "the template's non-printing layer did not arrive with its state"
        )

        let templateShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        templateShot.name = "phase31-template-import"
        templateShot.lifetime = .keepAlways
        add(templateShot)
    }

    @MainActor
    func testSetChipAndLayerRowKeepTheirOwnTouchTargets() throws {
        let app = launch()

        let metalRow = element("layer.row.0", app)
        XCTAssertTrue(metalRow.waitForExistence(timeout: 15), "the layer panel is missing")
        let current = element("layer.current", app)
        waitForLabel(current, "Metal", "the bench sample should open on Metal")

        element("layer.set.add", app).tap()
        waitForLabel(
            element("layer.set.current", app),
            "Set 2",
            "the new set was not activated"
        )
        waitForLabel(current, "Metal", "adding a set changed the current layer")

        // The switcher and the first row are adjacent, not overlapping. Prove
        // it from the actual frames rather than trusting the layout order.
        let defaultChip = element("layer.set.0", app)
        XCTAssertTrue(defaultChip.exists, "the default set chip is missing")
        XCTAssertLessThanOrEqual(
            defaultChip.frame.maxY,
            metalRow.frame.minY + 1,
            "the set switcher overlaps the first layer row"
        )

        // A boundary tap on the chip's bottom edge must switch the set and must
        // not fall through to the row underneath.
        defaultChip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        waitForLabel(
            element("layer.set.current", app),
            "Default",
            "the chip's own edge did not switch the set"
        )
        waitForLabel(current, "Metal", "a set-chip edge tap fell through to the layer row")

        // A boundary tap at the row's top edge must make it current without
        // switching the set back.
        metalRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        waitForLabel(current, "Metal", "the row's own edge did not make it current")
        waitForLabel(
            element("layer.set.current", app),
            "Default",
            "a row edge tap fell through to the set switcher"
        )

        let stonesRow = element("layer.row.1", app)
        stonesRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        waitForLabel(current, "Stones", "the Stones row did not become current")
        waitForLabel(
            element("layer.set.current", app),
            "Default",
            "selecting a row changed the active set"
        )

        let arbitrationShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        arbitrationShot.name = "phase31-set-row-arbitration"
        arbitrationShot.lifetime = .keepAlways
        add(arbitrationShot)
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

    @discardableResult
    private func waitForLabel(
        _ element: XCUIElement,
        _ expected: String,
        _ message: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        wait(element, "label", expected, message, timeout: timeout)
    }

    @discardableResult
    private func waitForValue(
        _ element: XCUIElement,
        _ expected: String,
        _ message: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        wait(element, "value", expected, message, timeout: timeout)
    }

    private func wait(
        _ element: XCUIElement,
        _ key: String,
        _ expected: String,
        _ message: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "%K CONTAINS %@", key, expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result != .completed {
            let actual = key == "label" ? element.label : (element.value as? String ?? "")
            XCTFail("\(message): \(key) was '\(actual)'")
            return false
        }
        return true
    }

    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
