import XCTest

final class AdaptiveShellTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testFiveWidthsStayUnclippedAndDoNotOverlap() throws {
        let app = launchLayoutLab()
        let widths: [CGFloat] = [640, 700, 820, 1024, 1366]

        for width in widths {
            let chip = app.buttons["layout.width.\(Int(width))"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "width chip \(Int(width)) is missing")
            chip.tap()

            let shell = element("shell", app)
            let tools = element("shell.tools", app)
            let viewport = element("shell.viewport", app)
            let inspector = element("shell.inspector", app)

            XCTAssertTrue(shell.waitForExistence(timeout: 5), "shell missing at \(Int(width)) pt")
            XCTAssertTrue(tools.exists, "tools zone missing at \(Int(width)) pt")
            XCTAssertTrue(viewport.exists, "viewport zone missing at \(Int(width)) pt")
            XCTAssertTrue(inspector.exists, "inspector zone missing at \(Int(width)) pt")

            let window = app.windows.firstMatch
            XCTAssertTrue(window.exists, "app window missing at \(Int(width)) pt")
            // The zone frames belong in the message: the shell is an
            // accessibility container, so its reported width is the union of
            // its children and a failure has to name which zone overflowed.
            XCTAssertEqual(
                shell.frame.width,
                width,
                accuracy: 3,
                """
                shell did not render at \(Int(width)) pt
                window=\(window.frame)
                shell=\(shell.frame)
                tools=\(tools.frame)
                viewport=\(viewport.frame)
                inspector=\(inspector.frame)
                hierarchy:
                \(app.debugDescription)
                """
            )
            XCTAssertGreaterThanOrEqual(shell.frame.minX, window.frame.minX - 1, "shell is clipped at the left edge")
            XCTAssertLessThanOrEqual(shell.frame.maxX, window.frame.maxX + 1, "shell is wider than the app window")
            XCTAssertGreaterThan(tools.frame.width, 0)
            XCTAssertGreaterThan(viewport.frame.width, 200)
            XCTAssertGreaterThan(inspector.frame.width, 0)

            XCTAssertGreaterThanOrEqual(tools.frame.minX, shell.frame.minX - 1)
            XCTAssertLessThanOrEqual(tools.frame.maxX, viewport.frame.minX + 1, "tools overlap viewport")
            XCTAssertLessThanOrEqual(viewport.frame.maxX, inspector.frame.minX + 1, "viewport overlaps inspector")
            XCTAssertLessThanOrEqual(inspector.frame.maxX, shell.frame.maxX + 1, "inspector escapes shell")

            let openGallery = app.buttons["shell.openGallery"]
            XCTAssertTrue(openGallery.exists, "app bar control missing at \(Int(width)) pt")
            XCTAssertGreaterThanOrEqual(openGallery.frame.height, 44, "app bar target below 44 pt")
            XCTAssertGreaterThanOrEqual(openGallery.frame.minX, shell.frame.minX - 1)
            XCTAssertLessThanOrEqual(openGallery.frame.maxX, shell.frame.maxX + 1)

            let bandWidth = app.textFields["Band width"]
            XCTAssertTrue(bandWidth.exists, "band-width field missing at \(Int(width)) pt")
            XCTAssertGreaterThanOrEqual(bandWidth.frame.minX, inspector.frame.minX - 1, "field clipped at left")
            XCTAssertLessThanOrEqual(bandWidth.frame.maxX, inspector.frame.maxX + 1, "field clipped at right")

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "adaptive-shell-\(Int(width))"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testCollapsiblePanelsReturnTheirWidthToTheViewport() throws {
        let app = launchLayoutLab()

        XCTAssertTrue(app.buttons["layout.width.820"].waitForExistence(timeout: 5))
        app.buttons["layout.width.820"].tap()

        let viewportBefore = element("shell.viewport", app)
        XCTAssertTrue(viewportBefore.waitForExistence(timeout: 5))
        let before = viewportBefore.frame.width

        let hideInspector = app.buttons["Hide inspector"]
        XCTAssertTrue(hideInspector.waitForExistence(timeout: 5))
        hideInspector.tap()

        waitForDisappearance(
            element("shell.inspector", app),
            timeout: 10,
            "inspector did not collapse after tapping Hide inspector"
        )
        let afterInspector = element("shell.viewport", app)
        XCTAssertTrue(afterInspector.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(afterInspector.frame.width, before + 200, "inspector width did not return to the viewport")

        let showInspector = app.buttons["Show inspector"]
        XCTAssertTrue(showInspector.waitForExistence(timeout: 10))
        showInspector.tap()
        XCTAssertTrue(element("shell.inspector", app).waitForExistence(timeout: 10))

        let hideTools = app.buttons["Hide tools"]
        XCTAssertTrue(hideTools.waitForExistence(timeout: 5))
        hideTools.tap()
        waitForDisappearance(
            element("shell.tools", app),
            timeout: 10,
            "tool rail did not collapse after tapping Hide tools"
        )

        let showTools = app.buttons["Show tools"]
        XCTAssertTrue(showTools.waitForExistence(timeout: 10))
        showTools.tap()
        XCTAssertTrue(element("shell.tools", app).waitForExistence(timeout: 10))

        let restored = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        restored.name = "adaptive-shell-restored"
        restored.lifetime = .keepAlways
        add(restored)
    }

    @MainActor
    private func launchLayoutLab() -> XCUIApplication {
        let app = XCUIApplication()
        // Tests share one simulator and the previous case can leave the app
        // running. Terminating it explicitly keeps `launch()` from failing with
        // "Failed to terminate" on a loaded runner.
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments = ["-FFLayoutLab"]
        app.launch()
        XCTAssertTrue(
            element("layoutLab.title", app).waitForExistence(timeout: 30),
            "layout laboratory did not launch. Hierarchy:\n\(app.debugDescription)"
        )

        // Rotate after launch and wait for the landscape window. Changing the
        // orientation before launch leaves the app in a transient square
        // window; screenshots then show the 1366 pt shell clipped even though
        // the accessibility frames report the requested width.
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        for _ in 0..<40 {
            if window.exists, window.frame.width > window.frame.height {
                Thread.sleep(forTimeInterval: 0.5)
                return app
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("app did not settle into a landscape window. Hierarchy:\n\(app.debugDescription)")
        return app
    }

    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// `waitForExistence` returns immediately when the element is already
    /// present, so it cannot prove a view disappeared. This waits on the
    /// `exists` predicate until the app finishes removing the view.
    private func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval,
        _ message: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, message)
    }
}
