import XCTest

/// Phase 38's user-visible half: opening a document written by an older
/// container revision must say so. The fixture writes a real bundle, rewrites
/// it as the bundle a version-1 app produced, and the shipping shell opens it
/// through the ordinary reader — so the status line under test is the line a
/// user sees, not a test-only string.
final class Phase38MigrationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testOpeningAVersion1BundleAnnouncesTheUpgrade() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments.append("-FFMigrationFixture")
        app.launch()

        let status = app.descendants(matching: .any)["shell.document.status"]
        XCTAssertTrue(
            status.waitForExistence(timeout: 30),
            "the shell never showed a document status"
        )

        let announced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Upgraded from format 1 to 2"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [announced], timeout: 20),
            .completed,
            "the status line did not announce the upgrade: \(status.label)"
        )
        XCTAssertTrue(
            status.label.contains("Legacy Pendant.ffp"),
            "the status line does not name the upgraded file: \(status.label)"
        )
        attach(app, "phase38-upgraded")

        // The announcement is not a substitute for the document: the viewport
        // is drawing the opened file, and the app is still in the foreground.
        let metal = app.descendants(matching: .any)["shell.viewport.metal"]
        XCTAssertTrue(metal.waitForExistence(timeout: 15), "the viewport did not appear")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Attachments

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
