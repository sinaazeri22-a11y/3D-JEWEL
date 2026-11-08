import XCTest

/// Phase 18's chip acceptance. Each viewport carries its own mode chip; a tap
/// cycles that pane and only that pane, so four-up can show a shaded Perspective
/// beside a technical Top. The screenshots show the rendered result, not just
/// the label.
final class DisplayModeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testModeChipCyclesOneViewportAtATime() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 30), "Metal viewport did not appear")

        let chip = element("shell.viewport.mode.perspective", app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "the perspective mode chip is missing")
        XCTAssertTrue(chip.label.contains("Shaded"), "a new document should open Shaded: '\(chip.label)'")

        let shadedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shadedShot.name = "phase18-shaded"
        shadedShot.lifetime = .keepAlways
        add(shadedShot)

        chip.tap()
        XCTAssertTrue(
            waitForLabel(chip, "Shaded with edges", "one tap did not advance to Shaded with edges")
        )

        chip.tap()
        XCTAssertTrue(waitForLabel(chip, "Clay", "the second tap did not reach Clay"))
        chip.tap()
        XCTAssertTrue(waitForLabel(chip, "Wireframe", "the third tap did not reach Wireframe"))

        let wireframeShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        wireframeShot.name = "phase18-wireframe"
        wireframeShot.lifetime = .keepAlways
        add(wireframeShot)

        // Four-up: each pane keeps its own mode. Change Perspective to Clay and
        // leave Top alone.
        app.buttons["shell.viewport.layout.fourUp"].tap()
        let topChip = element("shell.viewport.mode.top", app)
        XCTAssertTrue(topChip.waitForExistence(timeout: 15), "the Top pane has no mode chip")
        XCTAssertTrue(topChip.label.contains("Shaded"), "a new pane should open Shaded")

        // The four-up switch re-lays the HUD. Tapping while that layout is still
        // settling drops the press without cycling the mode, so wait for the
        // chip to be hittable and let the animation finish first.
        XCTAssertTrue(
            waitUntilHittable(chip, timeout: 15),
            "the Perspective mode chip is not hittable after the four-up switch"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        chip.tap()
        XCTAssertTrue(waitForLabel(chip, "Technical", "Perspective did not reach Technical"))
        XCTAssertTrue(
            topChip.label.contains("Shaded"),
            "changing Perspective also changed Top: '\(topChip.label)'"
        )

        let mixedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        mixedShot.name = "phase18-four-up-mixed"
        mixedShot.lifetime = .keepAlways
        add(mixedShot)
    }

    // MARK: - Helpers

    @discardableResult
    private func waitForLabel(
        _ element: XCUIElement,
        _ expected: String,
        _ message: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail("\(message): label was '\(element.label)'")
            return false
        }
        return true
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isHittable
    }

    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
