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
        XCTAssertFalse(multi.isSelected, "a fresh launch must not start in Multi mode")
        multi.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { multi.isSelected }),
            "the Multi chip did not turn on, so the next row tap would replace the selection"
        )
        XCTAssertTrue(reveal(stone, inspector: inspector), "the Stone row is missing")
        stone.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { ((stone.value as? String) ?? "").contains("selected") }),
            "Multi did not extend the selection to the stone"
        )
        // Both rows must remain selected: the group command groups exactly the
        // selection, so a dropped extend here would silently group one node.
        XCTAssertTrue(
            waitFor(timeout: 10, { ((shank.value as? String) ?? "").contains("selected") }),
            "Multi dropped Shank when Stone was added; value='\(shank.value ?? "")'"
        )

        // Multi must go off again: every later row tap in this test asserts a
        // single selection, and an extend tap would leave the old node in it.
        // Doing it here, while the chip is still above the just-tapped Stone,
        // avoids returning to it after grouping; switching the mode does not
        // change what is selected, which the next assertion proves.
        XCTAssertTrue(reveal(multi, inspector: inspector), "the Multi control left the inspector")
        multi.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { !multi.isSelected }),
            "the Multi chip did not turn off"
        )
        XCTAssertTrue(
            waitFor(timeout: 10, {
                ((shank.value as? String) ?? "").contains("selected")
                    && ((stone.value as? String) ?? "").contains("selected")
            }),
            "turning Multi off changed the selection before grouping"
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
            waitFor(timeout: 10, { ((group.value as? String) ?? "").contains("2 children") }),
            "the group did not report both children; value='\(group.value ?? "")'"
        )

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
        // Stop at the first swipe that puts the target on screen. Scrolling to
        // an end and back overshoots, and a tap issued while the scroll is
        // still settling is how an unchanged audit starts failing intermittently.
        // A successful reveal settles too: the chip's tap must not be read as
        // the scroll's deceleration.
        for _ in 0..<28 {
            if isVisible(element, in: inspector) { settle(); return true }
            // Move toward the target's actual frame instead of sweeping the
            // whole inspector: a full sweep both overshoots small panels and
            // takes long enough to hit the test's time allowance. A target
            // above the visible top needs the content to move down, and every
            // other case moves the content up.
            let top = inspector.frame.minY + 4
            scroll(inspector, up: element.frame.midY > top)
            settle()
        }
        let found = isVisible(element, in: inspector)
        if !found {
            let hierarchy = XCTAttachment(string: inspector.debugDescription)
            hierarchy.name = "phase33-reveal-failure-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "phase33-reveal-failure-screen"
            shot.lifetime = .keepAlways
            add(shot)
        }
        return found
    }

    /// `isHittable` alone lies for this inspector: an element below the scroll
    /// view's visible bounds can still report hittable, and the synthesized tap
    /// then lands on nothing. Require the element's frame to be wholly inside
    /// the inspector as well.
    @MainActor
    private func isVisible(_ element: XCUIElement, in inspector: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        return frame.minY >= inspector.frame.minY + 4 && frame.maxY <= visibleBottom(inspector)
    }

    /// The dock occupies its own space below the ScrollView, so the scroll's
    /// visible bottom is the dock's top.
    @MainActor
    private func visibleBottom(_ inspector: XCUIElement) -> CGFloat {
        let pinned = inspector.descendants(matching: .any)["array.panel"]
        let maxY = inspector.frame.maxY - 4
        return pinned.exists ? min(maxY, pinned.frame.minY) : maxY
    }

    /// Uses the system swipe the Phase 32 audit already proved on this
    /// inspector. A hand-built coordinate drag was tried first and failed in a
    /// way that is worth recording: after grouping, the scroll rested with the
    /// tree's help text under the drag's start point, and repeated drags from
    /// there changed the offset by nothing at all, while the same drags had
    /// moved the view before grouping. The system swipe starts on the row area
    /// and always pans, so the direction is chosen from the target's frame and
    /// overshoot is corrected by the next iteration.
    @MainActor
    private func scroll(_ inspector: XCUIElement, up: Bool) {
        if up {
            inspector.swipeUp()
        } else {
            inspector.swipeDown()
        }
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
