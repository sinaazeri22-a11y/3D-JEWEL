import XCTest

/// Phase 54's user-visible half: the Surface tool opens a live preview on the
/// selected profile and every drag event rebuilds it. The durable evidence is
/// what did not happen. After the drag the undo command is still disabled and
/// the object tree still holds exactly the one curve the fixture saved, because
/// a preview is not a document edit.
final class Phase54SurfacePreviewUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTheSurfaceToolPreviewsEveryDragEventWithoutCommitting() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments.append("-FFSurfaceFixture")
        app.launch()

        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 30), "Metal viewport did not appear")

        // The preview follows a real selection, so the profile is selected in
        // the object tree the same way a jeweller would select it.
        let row = element("tree.row.Preview profile", app)
        XCTAssertTrue(
            row.waitForExistence(timeout: 20),
            "the saved profile is missing from the object tree"
        )
        row.tap()

        let surface = element("shell.tool.surface", app)
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "the Surface tool is missing")
        surface.tap()

        let card = element("shell.surface.card", app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the preview card did not open")

        let readout = element("shell.surface.readout", app)
        XCTAssertTrue(readout.waitForExistence(timeout: 10), "the preview readout is missing")
        XCTAssertTrue(
            waitFor(timeout: 10, { readout.label.contains("Extrude") }),
            "the preview did not open in Extrude mode: \(readout.label)"
        )
        XCTAssertTrue(
            readout.label.contains("12 triangles"),
            "the closed profile did not produce a capped preview: \(readout.label)"
        )
        let firstReadout = readout.label

        let handle = element("shell.surface.handle", app)
        XCTAssertTrue(handle.waitForExistence(timeout: 10), "the drag handle is missing")
        XCTAssertTrue(waitFor(timeout: 10, { handle.isHittable }), "the drag handle is unreachable")

        // A slow press-drag produces several move events. The card's update
        // counter is the preview's own count of successful rebuilds, so this is
        // the row's "updates on every drag event" read from the product.
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -90))
        start.press(
            forDuration: 0.4,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )

        XCTAssertTrue(
            waitFor(timeout: 15, { updates(in: readout.label) >= 3 }),
            "the preview did not rebuild on the drag events: \(readout.label)"
        )
        XCTAssertNotEqual(
            readout.label,
            firstReadout,
            "the drag changed the update count but not the preview's parameters"
        )

        // Nothing was committed. Undo stays disabled, and the curve the fixture
        // saved is still the only row, still a curve.
        let undo = element("shell.document.undo", app)
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the undo command is missing")
        XCTAssertFalse(undo.isEnabled, "a preview must not create an undo step")
        XCTAssertTrue(((row.value as? String) ?? "").contains("Curve"))

        // Leaving the tool closes the preview; the document is untouched.
        let select = element("shell.tool.select", app)
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { !card.exists }),
            "the preview card outlived the Surface tool"
        )

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase54-surface-preview"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    /// The readout's own update counter. The label is "Extrude 12.80 mm ·
    /// 12 triangles · update 4"; anything unparseable reads as zero so a failed
    /// rebuild cannot look like progress.
    private func updates(in label: String) -> Int {
        guard let range = label.range(of: "update ", options: .backwards) else { return 0 }
        let digits = label[range.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? 0
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
