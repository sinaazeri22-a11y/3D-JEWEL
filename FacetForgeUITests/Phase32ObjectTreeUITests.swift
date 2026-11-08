import XCTest

/// Phase 32's acceptance in the shipping hierarchy. A solid is dragged into a
/// group, the rows are reordered inside it, search narrows by name and by type,
/// and a rename lands in the tree as one ordinary edit.
final class Phase32ObjectTreeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSolidDragsIntoGroupAndReordersInsideIt() throws {
        let app = launch()
        let inspector = element("shell.inspector", app)

        let groupChip = element("tree.addGroup", app)
        XCTAssertTrue(reveal(groupChip, inspector: inspector), "the object tree is missing")

        let stone = element("tree.row.Stone", app)
        let shank = element("tree.row.Shank", app)
        XCTAssertTrue(stone.waitForExistence(timeout: 10), "the Stone row is missing")
        XCTAssertTrue(shank.exists, "the Shank row is missing")
        XCTAssertTrue(
            (stone.value as? String)?.contains("selected") == true,
            "the tree did not mirror the viewport's initial stone selection"
        )

        groupChip.tap()
        let group = element("tree.row.Group 1", app)
        XCTAssertTrue(group.waitForExistence(timeout: 10), "the new group row did not appear")
        XCTAssertTrue(reveal(group, inspector: inspector), "the group row is not hittable")

        drag(stone, to: group)
        XCTAssertTrue(
            waitFor(timeout: 15, { ((stone.value as? String) ?? "").contains("level 2") }),
            "Stone was not nested under the group; value='\(stone.value ?? "")'"
        )
        XCTAssertTrue(
            ((group.value as? String) ?? "").contains("1 child"),
            "the group did not report its nested child: '\(group.value ?? "")'"
        )

        XCTAssertTrue(reveal(shank, inspector: inspector), "the Shank row is not hittable")
        drag(shank, to: group)
        XCTAssertTrue(
            waitFor(timeout: 15, { ((shank.value as? String) ?? "").contains("level 2") }),
            "Shank was not nested under the group; value='\(shank.value ?? "")'"
        )
        XCTAssertTrue(
            ((group.value as? String) ?? "").contains("2 children"),
            "the group did not report two children: '\(group.value ?? "")'"
        )

        // Children are now [Stone, Shank]. Select Shank and move it up; the
        // rendered order must flip, not merely the selection.
        shank.tap()
        let moveUp = element("tree.moveUp", app)
        XCTAssertTrue(reveal(moveUp, inspector: inspector), "the reorder control is missing")
        XCTAssertTrue(shank.frame.minY > stone.frame.minY, "the setup order is not Stone, Shank")
        moveUp.tap()
        XCTAssertTrue(
            waitFor(timeout: 15, { shank.frame.minY < stone.frame.minY }),
            "Up did not move Shank above Stone; shank=\(shank.frame) stone=\(stone.frame)"
        )

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase32-nested-and-reordered"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testSearchFindsByNameAndTypeAndRenameUpdatesTheRow() throws {
        let app = launch()
        let inspector = element("shell.inspector", app)

        let search = element("tree.search", app)
        XCTAssertTrue(reveal(search, inspector: inspector), "the tree search is missing")
        XCTAssertTrue(search.isHittable, "the tree search is not hittable")

        let stone = element("tree.row.Stone", app)
        let shank = element("tree.row.Shank", app)
        XCTAssertTrue(stone.waitForExistence(timeout: 10), "the Stone row is missing")
        XCTAssertTrue(shank.exists, "the Shank row is missing")

        search.tap()
        search.typeText("Stone")
        XCTAssertTrue(
            waitFor(timeout: 10, { !shank.exists }),
            "a name search did not hide the non-matching Shank row"
        )
        XCTAssertTrue(stone.exists, "the name search hid its own match")

        let clear = element("tree.search.clear", app)
        XCTAssertTrue(clear.isHittable, "the clear control is missing")
        clear.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { shank.exists }),
            "clearing the search did not restore the tree"
        )

        search.tap()
        search.typeText("solid")
        XCTAssertTrue(
            waitFor(timeout: 10, { shank.exists && !stone.exists }),
            "a type search did not isolate the solid"
        )

        clear.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { stone.exists }),
            "clearing the type search did not restore the stone"
        )

        stone.tap()
        let rename = element("tree.rename", app)
        XCTAssertTrue(reveal(rename, inspector: inspector), "the rename control is missing")
        rename.tap()

        let field = element("tree.rename.field", app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the rename sheet did not open")
        field.tap()
        field.typeText("Center Stone\n")

        let renamed = element("tree.row.Center Stone", app)
        XCTAssertTrue(
            renamed.waitForExistence(timeout: 15),
            "the renamed row did not replace the old one"
        )
        XCTAssertFalse(stone.exists, "the old row identifier survived the rename")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase32-search-and-rename"
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

    /// The tree sits below the layer panel, so the test scrolls the inspector
    /// until the requested control is actually hittable.
    @MainActor
    private func reveal(_ element: XCUIElement, inspector: XCUIElement) -> Bool {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return true }
            inspector.swipeUp()
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func drag(_ source: XCUIElement, to destination: XCUIElement) {
        source.press(forDuration: 1.0, thenDragTo: destination)
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
