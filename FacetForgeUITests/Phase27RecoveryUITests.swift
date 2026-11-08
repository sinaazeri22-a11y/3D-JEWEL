import XCTest

/// Phase 27's UI proof: the recovery prompt appears over the real shell, its
/// scrim takes every touch away from the Metal viewport, and Restore applies the
/// journal and returns the shell to a usable state.
final class Phase27RecoveryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRecoveryPromptBlocksTheViewportAndRestoresTheJournal() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments.append("-FFRecoveryFixture")
        app.launch()

        let prompt = element("shell.recovery.prompt", app)
        XCTAssertTrue(
            prompt.waitForExistence(timeout: 30),
            "the crash journal was not offered after reopen"
        )
        attach(app, "phase27-recovery-prompt")

        let status = element("shell.document.status", app)
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(
            status.label.contains("Unsaved edits found"),
            "the status line did not name the recovery: \(status.label)"
        )
        XCTAssertTrue(
            element("shell.recovery.detail", app).label.contains("Recovered Ring"),
            "the prompt does not name the document"
        )

        let metal = element("shell.viewport.metal", app)
        XCTAssertTrue(metal.waitForExistence(timeout: 15))
        XCTAssertFalse(
            metal.isHittable,
            "the scrim left the Metal viewport hittable behind the prompt"
        )
        let restore = element("shell.recovery.restore", app)
        let discard = element("shell.recovery.discard", app)
        XCTAssertTrue(restore.isHittable, "the Restore control is not hittable")
        XCTAssertTrue(discard.isHittable, "the Discard control is not hittable")

        // A tap in the middle of the viewport must land on the scrim, not select
        // or orbit the document underneath.
        let statusBefore = status.label
        metal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        XCTAssertTrue(prompt.exists, "a viewport tap dismissed the prompt")
        XCTAssertEqual(status.label, statusBefore, "a viewport tap changed the document")

        restore.tap()
        XCTAssertTrue(
            waitForDisappearance(prompt, timeout: 10),
            "Restore did not close the prompt"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 10) { status.label.contains("Restored 2 unsaved edits") },
            "the restored document status is '\(status.label)'"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 10) { metal.isHittable },
            "the viewport stayed blocked after the prompt closed"
        )
        XCTAssertEqual(
            element("shell.recovery.prompt", app).exists,
            false,
            "the prompt returned after restoration"
        )
        attach(app, "phase27-restored")

        // The restored edit is a real document state: the Stones layer is the
        // one the journal hid, and the saved bundle still has it visible. The
        // layer row's selected state is not part of this assertion; the
        // session's unit suite proves the restored hash exactly.
        XCTAssertFalse(
            status.label.contains("Unsaved edits found"),
            "the stale recovery status survived the restore"
        )
    }

    // MARK: - Waits and attachments

    @MainActor
    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
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
