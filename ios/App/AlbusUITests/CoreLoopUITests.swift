import XCTest

/// Drives the real app against the real backend: add an assignment, wait for
/// Albus to plan it, confirm the placed sessions appear, then walk the tabs the
/// plan feeds.
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

    /// Unique per test run.
    ///
    /// A shared constant meant the second test found the row the first had left
    /// behind and failed on "multiple matching elements" — the tests were
    /// coupled through the live database, which is exactly what a suite hitting
    /// a real backend must not be.
    private var assignmentTitle = ""

    override func setUp() {
        continueAfterFailure = false
        assignmentTitle = "Biology chapter \(UUID().uuidString.prefix(6))"
    }

    func testAddAssignmentProducesAPlacedPlan() throws {
        let app = XCUIApplication()
        app.launch()

        reachApp(app)
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Not signed in'")).element.exists,
            "sign-in failed")

        addAssignment(app, titled: assignmentTitle)

        // Assert through Tasks, not Today.
        //
        // Today only shows work the scheduler placed *today*, and late in the
        // evening it correctly places everything in tomorrow's study window
        // instead of at midnight. Asserting on Today therefore passed at noon
        // and failed at 23:58 — a test that fails for a reason the app is right
        // about. Tasks lists every assignment regardless of when its sessions
        // land, so this checks the same thing without depending on the clock.
        app.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts[assignmentTitle].waitForExistence(timeout: 90),
                      "no plan appeared — breakdown, persistence or scheduling failed")
    }

    /// The plan has to be reachable from Tasks and openable into its steps —
    /// the screens a student actually works from.
    func testPlanIsVisibleInTasksAndDetail() throws {
        let app = XCUIApplication()
        app.launch()
        reachApp(app)

        addAssignment(app, titled: assignmentTitle)

        app.buttons["Tasks"].tap()
        let card = app.staticTexts[assignmentTitle]
        XCTAssertTrue(card.waitForExistence(timeout: 90),
                      "the assignment is missing from Tasks")

        card.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["ALBUS'S PLAN"].waitForExistence(timeout: 10),
                      "task detail did not show the generated plan")

        // Every generated plan has at least one step, and each carries a
        // duration — the thing that proves steps rendered, not just a header.
        let durations = app.staticTexts.containing(
            NSPredicate(format: "label MATCHES %@", #"^\d+h( \d+m)?$|^\d+m$"#))
        XCTAssertGreaterThan(durations.count, 0, "no step durations rendered")
    }

    /// Tools is static, so this is cheap — but it is the one tab that opens
    /// external links, and a crash here would only ever be found by tapping.
    func testToolsLibraryRenders() throws {
        let app = XCUIApplication()
        app.launch()
        reachApp(app)

        app.buttons["Tools"].tap()
        XCTAssertTrue(app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Claude'")).element.waitForExistence(timeout: 5),
            "the tool library did not render")
    }

    // MARK: - Helpers

    /// Gets to the app proper, completing onboarding when it is showing.
    ///
    /// A fresh install has no account, so first launch lands in onboarding —
    /// which is also where the account is created. A later launch restores the
    /// session and goes straight through. Tests must tolerate both, because
    /// which one they get depends on what ran before them.
    private func reachApp(_ app: XCUIApplication) {
        let onboarding = app.staticTexts["A few things first."]
        let home = app.staticTexts["TODAY'S SCHEDULE"]

        // Whichever appears first decides the path.
        let start = Date()
        while Date().timeIntervalSince(start) < 25 {
            if home.exists { return }
            if onboarding.exists { break }
            usleep(200_000)
        }
        guard onboarding.exists else {
            XCTAssertTrue(home.waitForExistence(timeout: 20),
                          "neither onboarding nor the app appeared")
            return
        }

        app.buttons["Next"].tap()

        let task = app.textFields["e.g. History term paper"]
        XCTAssertTrue(task.waitForExistence(timeout: 5), "the deadline step never appeared")
        task.tap()
        task.typeText("Onboarding first assignment")

        app.buttons["Build my plan"].tap()

        // Account creation plus a real Claude call.
        let done = app.buttons["Show me"]
        XCTAssertTrue(done.waitForExistence(timeout: 120),
                      "onboarding never finished — account creation or the first plan failed")
        done.tap()

        XCTAssertTrue(home.waitForExistence(timeout: 20),
                      "onboarding completed but the app never appeared")
    }

    private func addAssignment(_ app: XCUIApplication, titled title: String) {
        app.buttons["Add assignment"].firstMatch.tap()

        let field = app.textFields["What is it?"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the add sheet never opened")
        field.tap()
        field.typeText(title)

        app.buttons["Plan it"].tap()
    }
}
