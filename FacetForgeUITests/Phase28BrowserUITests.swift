import XCTest

/// Phase 28's UI proof: a document created and saved from the workspace appears
/// in the browser, search narrows the grid, rename/duplicate/delete run through
/// the session, and every overlay takes the touch it draws above. No test-only
/// branch exists in the browser; the launch flag only seeds extra fixtures.
final class Phase28BrowserUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testBrowserSearchesRenamesDuplicatesDeletesAndOpensADocument() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments.append("-FFBrowserFixture")
        app.launch()

        // Create: the shipping shell's own New and Save commands make the file
        // the browser later lists. Nothing is seeded for this document.
        let newButton = element("shell.document.new", app)
        XCTAssertTrue(newButton.waitForExistence(timeout: 30), "the new-document command is missing")
        newButton.tap()
        let saveButton = element("shell.document.save", app)
        XCTAssertTrue(saveButton.waitForExistence(timeout: 15))
        saveButton.tap()
        let status = element("shell.document.status", app)
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(
            waitForCondition(timeout: 15) { status.label.contains("Saved Untitled.ffp") },
            "Save did not write the new document; status is '\(status.label)'"
        )

        let browserButton = element("shell.document.browser", app)
        XCTAssertTrue(
            browserButton.waitForExistence(timeout: 15),
            "the documents entry did not appear on the app bar"
        )
        XCTAssertTrue(browserButton.isHittable, "the documents entry is not hittable")
        browserButton.tap()

        let browser = element("shell.browser", app)
        XCTAssertTrue(browser.waitForExistence(timeout: 15), "the browser sheet did not open")
        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 15))
        XCTAssertFalse(
            metal.isHittable,
            "the browser left the Metal viewport hittable behind it"
        )
        attach(app, "phase28-browser")

        // Search finds the just-created bundle by the filename Save reported.
        let search = element("shell.browser.search", app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Untitled")
        XCTAssertTrue(
            waitForCondition(timeout: 10) { self.cells(app).count == 1 },
            "search for Untitled showed \(cells(app).count) cells"
        )
        let created = cells(app).firstMatch
        XCTAssertTrue(created.label.contains("Untitled"), "wrong search result: \(created.label)")
        created.tap()
        XCTAssertTrue(element("shell.browser.rename", app).isEnabled)

        // The rename sheet is above the browser: the search field and the
        // action row underneath must not be hittable while it is present.
        element("shell.browser.rename", app).tap()
        let renameSheet = element("shell.browser.rename.sheet", app)
        XCTAssertTrue(renameSheet.waitForExistence(timeout: 10), "the rename sheet did not open")
        XCTAssertFalse(search.isHittable, "the search field stayed hittable behind the rename sheet")
        XCTAssertFalse(
            element("shell.browser.delete", app).isHittable,
            "the delete action stayed hittable behind the rename sheet"
        )
        attach(app, "phase28-rename-sheet")

        let field = element("shell.browser.rename.field", app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(field.isHittable, "the rename field is not hittable")
        field.tap()
        // Submit from the keyboard, which is the same `save` path as the
        // button, and avoids depending on where the on-screen keyboard leaves
        // the button row.
        field.typeText("Phase28 Aurora\n")

        XCTAssertTrue(
            waitForDisappearance(renameSheet, timeout: 10),
            "Save did not close the rename sheet"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                element("shell.browser.message", app).label.contains("Renamed to Phase28 Aurora.ffp")
            },
            "the rename message did not appear"
        )
        // The old name is gone from the files, so the still-active query has no
        // result. This is the rename actually reaching disk, not just the row.
        XCTAssertTrue(
            waitForCondition(timeout: 10) { self.cells(app).count == 0 },
            "the old file name still matched after rename"
        )

        element("shell.browser.search.clear", app).tap()
        XCTAssertTrue(
            waitForCondition(timeout: 10) { self.cells(app).count >= 2 },
            "clearing the search did not restore the grid"
        )
        XCTAssertTrue(
            cellLabel(app, containing: "Phase28 Aurora") != nil,
            "the renamed document is not in the grid"
        )

        // Duplicate through the session, then delete the copy and leave the
        // original readable.
        search.tap()
        search.typeText("Aurora")
        XCTAssertTrue(
            waitForCondition(timeout: 10) { self.cells(app).count == 1 },
            "search for Aurora did not narrow to one cell"
        )
        cells(app).firstMatch.tap()
        element("shell.browser.duplicate", app).tap()
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                element("shell.browser.message", app).label.contains("Duplicated to Phase28 Aurora copy.ffp")
            },
            "the duplicate message did not appear"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 10) { self.cells(app).count == 2 },
            "the duplicate did not appear in the grid"
        )
        attach(app, "phase28-duplicated")

        let copy = cellElement(app, containing: "copy")
        XCTAssertNotNil(copy, "the duplicate cell is missing")
        copy?.tap()
        element("shell.browser.delete", app).tap()
        let confirm = app.buttons["Delete document"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the delete confirmation did not appear")
        confirm.tap()
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                element("shell.browser.message", app).label.contains("Deleted Phase28 Aurora copy.ffp")
            },
            "the delete message did not appear"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 10) { self.cells(app).count == 1 },
            "the deleted duplicate is still in the grid"
        )
        attach(app, "phase28-deleted")

        // Open the real bundle through the same session path save/reopen uses.
        cells(app).firstMatch.tap()
        element("shell.browser.open", app).tap()
        XCTAssertTrue(
            waitForDisappearance(browser, timeout: 10),
            "Open did not close the browser"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 10) { status.label.contains("Reopened Phase28 Aurora.ffp") },
            "Open did not load the document; status is '\(status.label)'"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 10) { metal.isHittable },
            "the viewport stayed blocked after the browser closed"
        )
        attach(app, "phase28-opened")
    }

    // MARK: - Queries, waits and attachments

    @MainActor
    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "shell.browser.cell")
    }

    @MainActor
    private func cellLabel(_ app: XCUIApplication, containing text: String) -> String? {
        cellElement(app, containing: text)?.label
    }

    @MainActor
    private func cellElement(_ app: XCUIApplication, containing text: String) -> XCUIElement? {
        let query = cells(app).matching(NSPredicate(format: "label CONTAINS %@", text))
        return query.count > 0 ? query.firstMatch : nil
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
