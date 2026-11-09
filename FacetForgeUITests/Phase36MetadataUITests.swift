import XCTest

/// Phase 36's UI proof, kept deliberately small: the sheet is opened from the
/// inspector's fixed header, one text field and one flag are edited, and the
/// real undo command is checked. The file-format round trip is proved by
/// `Phase36MetadataTests`, so this run does not spend a gate saving a bundle.
final class Phase36MetadataUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testMetadataSheetEditsPartNumberAndFlagWithOneUndo() throws {
        let app = launch()
        let sheet = element("metadata.sheet", app)
        let partNumber = element("metadata.field.partNumber", app)
        let stoneSetting = element("metadata.flag.stone-setting", app)
        let done = element("metadata.done", app)

        let launcher = element("inspector.metadata", app)
        XCTAssertTrue(launcher.waitForExistence(timeout: 10), "the Document info launcher is missing")
        XCTAssertTrue(launcher.isHittable, "the Document info launcher is not hittable")
        launcher.tap()
        expect(15, "the metadata sheet did not appear", app: app) { sheet.exists }

        let summary = element("metadata.stoneSummary", app)
        expect(10, "the stone summary is missing", app: app) { summary.exists }
        XCTAssertEqual(summary.label, "1 stone", "the stone summary disagreed with the tree")

        let firstStone = element("metadata.stone.0", app)
        expect(10, "the stone list is empty", app: app) { firstStone.exists }
        XCTAssertTrue(
            firstStone.label.contains("Stone") && firstStone.label.contains("Gem"),
            "the stone row did not name the stone and its material: '\(firstStone.label)'"
        )

        XCTAssertTrue(partNumber.isHittable, "the part-number field is not hittable")
        partNumber.tap()
        partNumber.typeText("FF-1042")
        XCTAssertEqual(partNumber.value as? String, "FF-1042")

        assertOnScreen(done, "the sheet's Done control is missing", app: app)
        done.tap()
        expect(10, "the metadata sheet did not close", app: app) { !sheet.exists }

        // Reopening reads document state, so the typed value proves the edit
        // committed through the session rather than sitting in the panel.
        launcher.tap()
        expect(15, "the metadata sheet did not reopen", app: app) { sheet.exists }
        expect(10, "the part number did not survive closing the sheet", app: app) {
            (partNumber.value as? String) == "FF-1042"
        }

        remindOnScreen(stoneSetting, app: app)
        XCTAssertFalse(stoneSetting.isSelected, "stone setting started selected")
        stoneSetting.tap()
        expect(10, "the stone-setting flag did not turn on", app: app) { stoneSetting.isSelected }

        assertOnScreen(done, "the sheet's Done control is missing", app: app)
        done.tap()
        expect(10, "the metadata sheet did not close", app: app) { !sheet.exists }

        // The flag is the last document change, so one Undo clears it and must
        // leave the previously typed part number untouched.
        let undo = element("shell.document.undo", app)
        assertOnScreen(undo, "the undo control is missing", app: app)
        undo.tap()

        launcher.tap()
        expect(15, "the metadata sheet did not reopen after undo", app: app) { sheet.exists }
        expect(10, "undo did not clear the stone-setting flag", app: app) {
            !stoneSetting.isSelected
        }
        XCTAssertEqual(
            partNumber.value as? String,
            "FF-1042",
            "undoing the flag also rolled back the part number"
        )

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase36-metadata-after-undo"
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

    /// The manufacturing chips sit below the notes; on a large sheet they fit,
    /// but bring the chip into the sheet before pressing it if a shorter layout
    /// ever puts it below the fold.
    @MainActor
    private func remindOnScreen(_ element: XCUIElement, app: XCUIApplication) {
        let sheet = self.element("metadata.sheet", app)
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            sheet.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        if !(element.exists && element.isHittable) {
            attachFailure(app, name: "phase36-chip")
            XCTFail("the stone-setting chip is not reachable; exists=\(element.exists)")
        }
    }

    @MainActor
    private func assertOnScreen(
        _ element: XCUIElement,
        _ message: String,
        app: XCUIApplication
    ) {
        if element.exists && element.isHittable { return }
        attachFailure(app, name: "phase36-onscreen")
        XCTFail("\(message); exists=\(element.exists) hittable=\(element.isHittable)")
    }

    @MainActor
    private func expect(
        _ timeout: TimeInterval,
        _ message: String,
        app: XCUIApplication,
        _ condition: @escaping () -> Bool
    ) {
        if waitFor(timeout: timeout, condition) { return }
        attachFailure(app, name: "phase36-expect")
        XCTFail(message)
    }

    @MainActor
    private func attachFailure(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(name)-screen"
        shot.lifetime = .keepAlways
        add(shot)
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
