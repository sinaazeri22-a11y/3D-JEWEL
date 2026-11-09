import XCTest

/// Phase 35's acceptance in the shipping hierarchy. The material sheet is
/// reached from the inspector header, the selected shank's material is changed
/// through two alloy presets, and Undo restores the previous one. Each preset
/// edit is one document command, so the same Undo that reverts the surface
/// values leaves the earlier preset in place.
final class Phase35MaterialUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testMaterialSheetAppliesAlloyPresetsAndUndoRestoresThePreviousOne() throws {
        let app = launch()
        let inspector = element("shell.inspector", app)

        // The launch selection is the stone; the material test wants the metal
        // object so the preset edits the gold material, not the gem.
        let shank = element("tree.row.Shank", app)
        XCTAssertTrue(reveal(shank, inspector: inspector, app: app), "the Shank row is missing")
        shank.tap()
        expect(10, "tapping Shank did not select it", app: app) {
            ((shank.value as? String) ?? "").contains("selected")
        }

        // The material launcher sits at the top of the inspector's scroll
        // content, so reaching the sheet means being at that top, not merely
        // having the control exist somewhere in the hierarchy.
        let materials = element("inspector.materials", app)
        XCTAssertTrue(
            revealTop(materials, inspector: inspector, app: app),
            "the Materials header control is not reachable"
        )
        materials.tap()

        let sheet = element("material.sheet", app)
        expect(15, "the material sheet did not appear", app: app) { sheet.exists }

        let node = element("material.node", app)
        expect(10, "the sheet did not name the selected object", app: app) { node.exists }
        XCTAssertTrue(node.label.contains("Shank"), "the sheet named the wrong object: '\(node.label)'")
        XCTAssertTrue(
            node.label.contains("6720 faces"),
            "the shank's face count is wrong: '\(node.label)'"
        )

        let usage = element("material.usage", app)
        expect(10, "the material usage line is missing", app: app) { usage.exists }
        XCTAssertTrue(usage.label.contains("6720 faces"), "usage='\(usage.label)'")

        // A preset edit is a real document change even from a custom surface.
        let gold = element("material.preset.yellow-gold-18k", app)
        XCTAssertTrue(
            revealInSheet(gold, sheet: sheet, app: app),
            "the yellow-gold preset is not reachable"
        )
        gold.tap()
        expect(10, "the yellow-gold preset did not become selected", app: app) {
            gold.isSelected
        }

        let rose = element("material.preset.rose-gold-18k", app)
        XCTAssertTrue(
            revealInSheet(rose, sheet: sheet, app: app),
            "the rose-gold preset is not reachable"
        )
        rose.tap()
        expect(10, "the rose-gold preset did not become selected", app: app) {
            rose.isSelected
        }

        let roughness = element("material.roughness.value", app)
        expect(10, "the preset did not write its roughness of 0.20", app: app) {
            roughness.label == "0.20"
        }
        XCTAssertFalse(gold.isSelected, "applying rose gold left yellow gold selected")

        let done = element("material.done", app)
        assertOnScreen(done, "the sheet's Done control is missing", app: app)
        done.tap()
        expect(10, "the material sheet did not close", app: app) { !sheet.exists }

        // The rose-gold edit is the last document change, so one Undo restores
        // the yellow-gold preset rather than the custom surface before it.
        let undo = element("shell.document.undo", app)
        assertOnScreen(undo, "the undo control is missing", app: app)
        undo.tap()

        XCTAssertTrue(
            revealTop(materials, inspector: inspector, app: app),
            "the Materials header control is not reachable after undo"
        )
        materials.tap()
        expect(15, "the material sheet did not reopen", app: app) { sheet.exists }
        expect(10, "undo did not restore the yellow-gold preset", app: app) {
            gold.isSelected
        }
        XCTAssertFalse(rose.isSelected, "undo left the rose-gold preset selected")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase35-material-inspector-after-undo"
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

    /// The tree and the transform panel share the inspector's scroll view. Stop
    /// at the first swipe that puts the target on screen; scrolling to an end
    /// and back overshoots, and a tap issued while the scroll is still settling
    /// is how an unchanged audit starts failing intermittently.
    @MainActor
    private func reveal(
        _ element: XCUIElement,
        inspector: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        for _ in 0..<28 {
            if isVisible(element, in: inspector) {
                settle()
                return true
            }
            let top = inspector.frame.minY + 4
            if element.frame.midY > top {
                inspector.swipeUp()
            } else {
                inspector.swipeDown()
            }
            settle()
        }
        let found = isVisible(element, in: inspector)
        if !found { attachFailure(app, name: "phase35-reveal") }
        return found
    }

    /// The material launcher is the first control in the scroll content, so a
    /// reveal that moved down for the tree has to come back up before the
    /// sheet can be opened from it.
    @MainActor
    private func revealTop(
        _ element: XCUIElement,
        inspector: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        for _ in 0..<10 {
            if isVisible(element, in: inspector) {
                settle()
                return true
            }
            inspector.swipeDown()
            settle()
        }
        let found = isVisible(element, in: inspector)
        if !found { attachFailure(app, name: "phase35-reveal-top") }
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
        return frame.minY >= inspector.frame.minY + 4
            && frame.maxY <= visibleBottom(inspector)
    }

    /// The docked array panel sits below the ScrollView, so the scroll's
    /// visible bottom is its top when an array is selected.
    @MainActor
    private func visibleBottom(_ inspector: XCUIElement) -> CGFloat {
        let pinned = inspector.descendants(matching: .any)["array.panel"]
        let maxY = inspector.frame.maxY - 4
        return pinned.exists ? min(maxY, pinned.frame.minY) : maxY
    }

    /// The sheet scrolls independently of the inspector, and its chip grid can
    /// be below the first screenful. Move toward the chip's own frame rather
    /// than sweeping, and require the chip's frame inside the sheet.
    @MainActor
    private func revealInSheet(
        _ element: XCUIElement,
        sheet: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        for _ in 0..<20 {
            if isInSheet(element, sheet: sheet) {
                settle()
                return true
            }
            if element.exists, element.frame.midY < sheet.frame.minY + 80 {
                sheet.swipeDown()
            } else {
                sheet.swipeUp()
            }
            settle()
        }
        let found = isInSheet(element, sheet: sheet)
        if !found { attachFailure(app, name: "phase35-sheet-reveal") }
        return found
    }

    @MainActor
    private func isInSheet(_ element: XCUIElement, sheet: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        return frame.minY >= sheet.frame.minY + 4
            && frame.maxY <= sheet.frame.maxY - 4
    }

    /// A control the test must press has to be on screen. Record the state
    /// before failing so a red run explains itself without another iteration.
    @MainActor
    private func assertOnScreen(
        _ element: XCUIElement,
        _ message: String,
        app: XCUIApplication
    ) {
        if element.exists && element.isHittable { return }
        attachFailure(app, name: "phase35-onscreen")
        XCTFail("\(message); exists=\(element.exists) hittable=\(element.isHittable)")
    }

    /// A bounded wait with the failure artifacts attached, so the first red
    /// run already shows whether the sheet updated, the tap missed or the
    /// control was never there.
    @MainActor
    private func expect(
        _ timeout: TimeInterval,
        _ message: String,
        app: XCUIApplication,
        _ condition: @escaping () -> Bool
    ) {
        if waitFor(timeout: timeout, condition) { return }
        attachFailure(app, name: "phase35-expect")
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
