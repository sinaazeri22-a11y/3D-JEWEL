import XCTest

/// Phase 55's user-visible half: name a curve, save it, kill the app, launch it
/// again and insert the saved curve. The durable evidence is a row in the
/// object tree that only the insert could have produced, and one undo that
/// removes it again; the library file, not the document, has to survive the
/// relaunch for the second launch to find the entry at all.
final class Phase55CurveLibraryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 420
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testASavedCurveSurvivesRelaunchAndInsertsAsOneUndoableEdit() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments = ["-FFCurveLibraryFixture"]
        app.launch()

        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 30), "Metal viewport did not appear")

        // The fixture's curve is selected the way a jeweller selects it.
        let source = element("tree.row.Library source", app)
        XCTAssertTrue(source.waitForExistence(timeout: 20), "the fixture's curve is missing")
        source.tap()

        let toggle = element("shell.curves.toggle", app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the library toggle is missing")
        XCTAssertTrue(waitFor(timeout: 10, { toggle.isHittable }), "the library toggle is unreachable")
        toggle.tap()

        let card = element("shell.curves.card", app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the library card did not open")

        let name = element("shell.curves.name", app)
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the name field is missing")
        name.tap()
        name.typeText("Wave 1\n")

        let save = element("shell.curves.save", app)
        XCTAssertTrue(waitFor(timeout: 10, { save.isHittable }), "the save chip is unreachable")
        save.tap()

        let entry = element("shell.curves.entry.0", app)
        XCTAssertTrue(waitFor(timeout: 15, { entry.exists }), "the saved curve did not appear in the card")
        XCTAssertTrue(
            waitFor(timeout: 10, { app.staticTexts["Wave 1"].exists }),
            "the card does not show the typed name"
        )

        // The library is a file beside the documents, so a real relaunch is the
        // only honest proof it survived. The second fixture opens an empty
        // document and deliberately leaves the library alone.
        app.terminate()
        app.launchArguments = ["-FFCurveLibraryReopen"]
        app.launch()
        XCTAssertTrue(
            element("shell.viewport.metal", app).waitForExistence(timeout: 30),
            "the viewport did not come back after the relaunch"
        )

        let toggleAgain = element("shell.curves.toggle", app)
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 10), "the library toggle is missing after relaunch")
        XCTAssertTrue(waitFor(timeout: 10, { toggleAgain.isHittable }))
        toggleAgain.tap()

        let entryAgain = element("shell.curves.entry.0", app)
        XCTAssertTrue(
            waitFor(timeout: 15, { entryAgain.exists }),
            "the saved curve did not survive the relaunch"
        )
        XCTAssertTrue(app.staticTexts["Wave 1"].exists, "the re-read entry lost its name")

        // The target document is empty, so this row can only come from insert.
        XCTAssertFalse(element("tree.row.Wave 1", app).exists, "the target document was not empty")

        let insert = element("shell.curves.insert.0", app)
        XCTAssertTrue(insert.waitForExistence(timeout: 10), "the insert chip is missing")
        insert.tap()

        let inserted = element("tree.row.Wave 1", app)
        XCTAssertTrue(inserted.waitForExistence(timeout: 15), "the inserted curve is missing from the tree")

        let undo = element("shell.document.undo", app)
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the undo command is missing")
        XCTAssertTrue(undo.isEnabled, "an insert must be undoable")

        undo.tap()
        XCTAssertTrue(waitFor(timeout: 10, { !inserted.exists }), "one undo did not remove the inserted curve")
        XCTAssertFalse(undo.isEnabled, "the insert was the only edit")

        // Undo touched the document, not the library: the entry is still there.
        XCTAssertTrue(entryAgain.exists, "undoing the insert must not remove the saved curve")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase55-curve-library"
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
