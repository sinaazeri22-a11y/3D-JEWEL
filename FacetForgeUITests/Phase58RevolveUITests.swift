import XCTest

/// Phase 58's user-visible half: a jeweller opens the Surface card on a saved
/// section, switches it to Revolve, types an angle, reverses the direction, and
/// gets one solid node that one undo takes away again.
///
/// The profile comes from a saved bundle written by this build and opened by the
/// real reader, so the card is reading document geometry rather than a fixture
/// built in memory. The file's own name and its cleared journal mean this test
/// never inherits another test's recovered edit.
final class Phase58RevolveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTheRevolveCardCommitsOneSolidThatOneUndoRemoves() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments.append("-FFRevolveFixture")
        app.launch()

        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 30), "Metal viewport did not appear")

        let profile = element("tree.row.Revolve profile", app)
        XCTAssertTrue(
            profile.waitForExistence(timeout: 20),
            "the saved section is missing from the object tree"
        )
        XCTAssertTrue(((profile.value as? String) ?? "").contains("Curve"))
        profile.tap()

        let surface = element("shell.tool.surface", app)
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "the Surface tool is missing")
        surface.tap()

        let card = element("shell.surface.card", app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the preview card did not open")
        let readout = element("shell.surface.readout", app)
        XCTAssertTrue(readout.waitForExistence(timeout: 10), "the preview readout is missing")
        XCTAssertTrue(
            waitFor(timeout: 10, { readout.label.contains("Extrude") }),
            "the card did not open in Extrude mode: \(readout.label)"
        )

        // The mode chip the card already carried now opens a real revolve, not a
        // preview-only ghost.
        let revolveChip = element("shell.surface.mode.revolve", app)
        XCTAssertTrue(revolveChip.waitForExistence(timeout: 10))
        revolveChip.tap()
        XCTAssertTrue(
            waitFor(timeout: 15, { readout.label.contains("Revolve") }),
            "the card did not switch to revolve: \(readout.label)"
        )

        // The angle is typed into the card's own field. The field shows the
        // effective 90 degrees, so the test clears it first the way a person
        // would; the session clamps as it types.
        let angle = element("shell.revolve.angle", app)
        XCTAssertTrue(angle.waitForExistence(timeout: 10), "the angle field is missing")
        XCTAssertTrue(waitFor(timeout: 10, { angle.isHittable }), "the angle field is unreachable")
        angle.tap()
        angle.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "180\n"
        )
        XCTAssertTrue(
            waitFor(timeout: 10, { readout.label.contains("180") }),
            "the typed angle did not reach the body: \(readout.label)"
        )

        // Direction is a real choice for a partial turn, and the card says so.
        let reversed = element("shell.revolve.direction.reversed", app)
        XCTAssertTrue(reversed.waitForExistence(timeout: 10), "the direction chip is missing")
        XCTAssertTrue(waitFor(timeout: 10, { reversed.isHittable }), "the direction chip is unreachable")
        reversed.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { readout.label.contains("reversed") }),
            "the reversed direction did not reach the readout: \(readout.label)"
        )

        // A closed profile at a partial turn is the one case with ends, so both
        // cap choices are on screen.
        XCTAssertTrue(
            element("shell.revolve.caps.capped", app).waitForExistence(timeout: 10),
            "the capped choice is missing on a partial turn"
        )
        XCTAssertTrue(
            element("shell.revolve.caps.open", app).waitForExistence(timeout: 10),
            "the open choice is missing on a partial turn"
        )

        let commit = element("shell.revolve.commit", app)
        XCTAssertTrue(commit.waitForExistence(timeout: 10), "the commit button is missing")
        XCTAssertTrue(commit.isEnabled, "the commit is disabled with a live preview")
        XCTAssertTrue(waitFor(timeout: 10, { commit.isHittable }), "the commit is unreachable")
        let undo = element("shell.document.undo", app)
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the undo command is missing")
        XCTAssertFalse(undo.isEnabled, "a preview must not create an undo step")
        commit.tap()

        let body = element("tree.row.Revolve", app)
        XCTAssertTrue(
            body.waitForExistence(timeout: 20),
            "the committed solid is missing from the object tree"
        )
        XCTAssertTrue(
            ((body.value as? String) ?? "").contains("Solid"),
            "the new row is not a solid: \((body.value as? String) ?? "nil")"
        )

        XCTAssertTrue(waitFor(timeout: 10, { undo.isEnabled }), "the commit created no undo step")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase58-revolve"
        shot.lifetime = .keepAlways
        add(shot)

        undo.tap()
        XCTAssertTrue(
            waitFor(timeout: 15, { !body.exists }),
            "one undo did not remove the revolved body"
        )
        XCTAssertTrue(profile.exists, "the sketch the body came from was consumed")
        XCTAssertTrue(((profile.value as? String) ?? "").contains("Curve"))
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
