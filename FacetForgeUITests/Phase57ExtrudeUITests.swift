import XCTest

/// Phase 57's user-visible half: a jeweller sets a draft and a symmetric mode on
/// the extrusion card, taps Create solid, and gets one solid node that one undo
/// takes away again.
///
/// The profile comes from a saved bundle written by this build and opened by the
/// real reader, so the card is reading document geometry rather than a fixture
/// the test built in memory. The assertion after the commit is the object tree's
/// own row: a Solid, next to the Curve it was made from.
final class Phase57ExtrudeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        executionTimeAllowance = 360
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTheExtrusionCardCommitsOneSolidThatOneUndoRemoves() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments.append("-FFExtrudeFixture")
        app.launch()

        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 30), "Metal viewport did not appear")

        let profile = element("tree.row.Extrude profile", app)
        XCTAssertTrue(
            profile.waitForExistence(timeout: 20),
            "the saved profile is missing from the object tree"
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
        XCTAssertTrue(
            readout.label.contains("12 triangles"),
            "the closed profile did not produce a capped preview: \(readout.label)"
        )

        // The draft is typed into the card's own field. An undrafted body leaves
        // the field empty, so "3" is three degrees rather than a digit appended
        // to a zero.
        let draft = element("shell.extrude.draft", app)
        XCTAssertTrue(draft.waitForExistence(timeout: 10), "the draft field is missing")
        XCTAssertTrue(waitFor(timeout: 10, { draft.isHittable }), "the draft field is unreachable")
        draft.tap()
        draft.typeText("3\n")
        XCTAssertTrue(
            waitFor(timeout: 10, { readout.label.contains("draft") }),
            "the draft did not reach the preview: \(readout.label)"
        )

        // Symmetric mode is the row's other parameter with a visible shape: the
        // ghost now straddles the sketch plane, and the readout says so.
        let symmetric = element("shell.extrude.symmetric", app)
        XCTAssertTrue(symmetric.waitForExistence(timeout: 10), "the Symmetric chip is missing")
        symmetric.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { readout.label.contains("symmetric") }),
            "symmetric mode did not reach the preview: \(readout.label)"
        )

        // Nothing has been committed: undo is still disabled and the tree still
        // holds exactly the one curve.
        let undo = element("shell.document.undo", app)
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the undo command is missing")
        XCTAssertFalse(undo.isEnabled, "preview parameters must not create undo steps")

        let commit = element("shell.extrude.commit", app)
        XCTAssertTrue(commit.waitForExistence(timeout: 10), "the Create solid button is missing")
        XCTAssertTrue(waitFor(timeout: 10, { commit.isHittable }), "Create solid is unreachable")
        commit.tap()

        let solid = element("tree.row.Extrusion", app)
        XCTAssertTrue(
            solid.waitForExistence(timeout: 15),
            "the committed solid is missing from the object tree"
        )
        XCTAssertTrue(
            ((solid.value as? String) ?? "").contains("Solid"),
            "the committed node is not a solid: \(solid.value ?? "nil")"
        )
        XCTAssertTrue(
            waitFor(timeout: 10, { undo.isEnabled }),
            "the commit did not create an undo step"
        )
        XCTAssertTrue(
            waitFor(timeout: 10, { !card.exists }),
            "the card outlived the commit it consumed"
        )

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phase57-extrusion-committed"
        shot.lifetime = .keepAlways
        add(shot)

        // One undo, and the body is gone while the profile it came from stays.
        undo.tap()
        XCTAssertTrue(
            waitFor(timeout: 10, { !solid.exists }),
            "undo did not remove the committed solid"
        )
        XCTAssertTrue(profile.exists, "undo must not remove the profile the body was made from")
        XCTAssertFalse(undo.isEnabled)
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
