import XCTest

/// Drives the real app against the real backend: add an assignment, wait for
/// Albus to plan it, confirm the placed sessions appear.
///
/// Deliberately not mocked. The seam between app and backend is the one place
/// nothing else exercises — every bug found while building this connection
/// (a missing config value, a reserved error code, an env prefix) lived
/// exactly there and was invisible to unit tests and to a passing build.
///
/// Kept out of the default test plan because it costs a real Anthropic call.
/// Run explicitly:
///   xcodebuild test -scheme Albus -only-testing:AlbusUITests
/// `@MainActor` is required, not stylistic: XCUITest's APIs are main-actor
/// isolated under Swift 6, and Xcode 16.4 rejects calling them from a
/// nonisolated test method. Xcode 26 accepted it locally, so this only failed
/// on CI — which is exactly why CI compiles the target even when skipping it.
@MainActor
final class CoreLoopUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testAddAssignmentProducesAPlacedPlan() throws {
        let app = XCUIApplication()
        app.launch()

        // The app signs in silently on launch; the header proves it got that far.
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 20),
                      "Today screen never appeared — sign-in or the shell failed")
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Not signed in'")).element.exists,
            "anonymous sign-in failed")

        app.buttons["Add assignment"].tap()

        let title = app.textFields["What is it?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Read chapter 12 of the biology textbook")

        app.buttons["Plan it"].tap()

        // A real Claude call plus scheduling. Generous, because the point is
        // whether it lands at all, not how fast.
        let planned = app.staticTexts["Read chapter 12 of the biology textbook"]
        XCTAssertTrue(planned.waitForExistence(timeout: 90),
                      "no session appeared — breakdown, persistence or scheduling failed")

        // Sessions carry a time range; its presence means the scheduler placed
        // the work rather than merely storing it.
        let summary = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'session'")).element
        XCTAssertTrue(summary.waitForExistence(timeout: 10),
                      "assignment saved but nothing was placed in time")
    }
}
