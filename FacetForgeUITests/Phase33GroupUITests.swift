import XCTest

/// Phase 33's acceptance in the shipping hierarchy. The launch stone is grouped
/// from the tree, the transform panel names the group it inherits from, a pivot
/// preset is one undoable edit, and ungrouping returns the stone to the root.
final class Phase33GroupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testGroupSelectionPivotsAndUngroupsThroughThePanel() throws {
        let app = launch()
        let inspector = element("shell.inspector", app)

        let stone = element("tree.row.Stone", app)
        XCTAssertTrue(reveal(stone, inspector: inspector), "the Stone row is missing")
        XCTAssertTrue(
            (stone.value as? String)?.contains("selected") == true,
            "the launch selection is not the stone; value='\(stone.value ?? "")'"
        )

        // Two roots must be grouped together: a group around one node whose
        // bounds are centred on the origin would start at the zero pivot, and
        // the Origin preset below would then be a no-op rather than an edit.
        let shank = element("tree.row.Shank", app)
        XCTAssertTrue(reveal(shank, inspector: inspector), "the Shank row is missing")
        shank.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { ((shank.value as? String) ?? "").contains("selected") }),
            "tapping Shank did not select it"
        )

        let multi = element("selection.multi", app)
        XCTAssertTrue(reveal(multi, inspector: inspector), "the Multi control is missing")
        multi.tap()
        XCTAssertTrue(reveal(stone, inspector: inspector), "the Stone row is missing")
        stone.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { ((stone.value as? String) ?? "").contains("selected") }),
            "Multi did not extend the selection to the stone"
        )

        let groupChip = element("tree.groupSelection", app)
        XCTAssertTrue(reveal(groupChip, inspector: inspector), "the group command is missing")
        XCTAssertTrue(groupChip.isEnabled, "two unlocked sibling roots should be groupable")
        groupChip.tap()

        let group = element("tree.row.Group 1", app)
        XCTAssertTrue(group.waitForExistence(timeout: 15), "the group row did not appear")
        XCTAssertTrue(
            waitFor(timeout: 10, { ((group.value as? String) ?? "").contains("selected") }),
            "the new group did not become the selection; value='\(group.value ?? "")'"
        )
        XCTAssertTrue(
            ((group.value as? String) ?? "").contains("2 children"),
            "the group did not report both children; value='\(group.value ?? "")'"
        )

        // Multi must go off again: every later row tap in this test asserts a
        // single selection, and an extend tap would leave the old node in it.
        XCTAssertTrue(reveal(multi, inspector: inspector), "the Multi control left the inspector")
        multi.tap()
        XCTAssertTrue(
            waitFor(timeout: 15, { ((stone.value as? String) ?? "").contains("level 2") }),
            "Stone did not nest under the new group; value='\(stone.value ?? "")'"
        )

        // The group starts with a pivot at the centre of what it contains, so
        // the Origin preset is a real edit: it moves the pivot to the local zero
        // and Undo must restore the old readout without also undoing the
        // grouping.
        let pivot = element("transform.pivot", app)
        XCTAssertTrue(reveal(pivot, inspector: inspector), "the pivot readout is missing")
        let originalPivot = pivot.label
        let originPreset = element("transform.pivot.origin", app)
        XCTAssertTrue(reveal(originPreset, inspector: inspector), "the Origin preset is missing")
        originPreset.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { pivot.label != originalPivot }),
            "the Origin preset did not move the pivot; label='\(pivot.label)'"
        )
        let movedPivot = pivot.label

        let undo = element("shell.document.undo", app)
        XCTAssertTrue(undo.isHittable, "the undo control is missing")
        undo.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { pivot.label == originalPivot }),
            "undo did not restore the old pivot; label='\(pivot.label)'"
        )

        // The stone inherits the group's transform, and with an identity group
        // its world readout must equal its local one.
        XCTAssertTrue(reveal(stone, inspector: inspector), "the Stone row is not reachable")
        stone.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { ((stone.value as? String) ?? "").contains("selected") }),
            "tapping the Stone row did not select it"
        )
        let inherits = element("transform.inherits", app)
        XCTAssertTrue(reveal(inherits, inspector: inspector), "the transform panel is missing")
        XCTAssertTrue(
            waitFor(timeout: 10, { inherits.label.contains("Inherits Group 1") }),
            "the inheritance readout did not name the group; label='\(inherits.label)'"
        )

        let local = element("transform.local", app)
        let world = element("transform.world", app)
        XCTAssertTrue(local.exists && world.exists, "the local/world readouts are missing")
        XCTAssertEqual(
            local.label.replacingOccurrences(of: "Local ", with: ""),
            world.label.replacingOccurrences(of: "World ", with: ""),
            "an identity group changed the stone's world position"
        )

        // Group and ungroup: both children return to level 1 and a world root.
        XCTAssertTrue(reveal(group, inspector: inspector), "the group row is not reachable")
        group.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { ((group.value as? String) ?? "").contains("selected") }),
            "tapping the group row did not select it"
        )
        let ungroup = element("tree.ungroup", app)
        XCTAssertTrue(reveal(ungroup, inspector: inspector), "the ungroup command is missing")
        XCTAssertTrue(ungroup.isEnabled, "the selected unlocked group should be ungroupable")
        ungroup.tap()
        XCTAssertTrue(waitFor(timeout: 15, { !group.exists }), "the group row survived ungroup")
        XCTAssertTrue(
            waitFor(timeout: 15, {
                ((stone.value as? String) ?? "").contains("level 1")
                    && ((shank.value as? String) ?? "").contains("level 1")
            }),
            "a child did not return to the root; stone='\(stone.value ?? "")' shank='\(shank.value ?? "")'"
        )

        XCTAssertTrue(reveal(stone, inspector: inspector), "the Stone row is not reachable")
        stone.tap()
        XCTAssertTrue(reveal(inherits, inspector: inspector), "the transform panel left the inspector")
        XCTAssertTrue(
            waitFor(timeout: 10, { inherits.label.contains("World root") }),
            "a root node still reported inheritance; label='\(inherits.label)'"
        )
        XCTAssertNotEqual(movedPivot, originalPivot, "sanity: the preset changed the pivot")
        XCTAssertTrue(movedPivot.contains("0.000"), "the Origin preset did not land on zero: '\(movedPivot)'")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase33-group-pivot-inheritance"
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

    /// The tree and the transform panel share the inspector's scroll view, and
    /// the test has to move both ways: up to the tree's chips and rows, down to
    /// the transform readouts. A one-directional reveal would strand the runner
    /// at whichever end it reached first.
    @MainActor
    private func reveal(_ element: XCUIElement, inspector: XCUIElement) -> Bool {
        if isHittable(element) { return true }
        // Stop at the first swipe that puts the target on screen. Scrolling to
        // an end and back overshoots, and a tap issued while the scroll is
        // still settling is how an unchanged audit starts failing intermittently.
        for _ in 0..<8 {
            inspector.swipeUp()
            settle()
            if isHittable(element) { return true }
        }
        for _ in 0..<14 {
            inspector.swipeDown()
            settle()
            if isHittable(element) { return true }
        }
        return isHittable(element)
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
