import XCTest

/// The IB-only route through onboarding.
///
/// Deliberately cheap: it stops before "Build my plan", so it creates no account
/// and costs no model call. It proves the one-option programme picker stays out
/// of the way while IB subjects and their assessment components remain wired.
@MainActor
final class CurriculumOnboardingUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        // Forces onboarding regardless of what a previous test left behind.
        // `-key value` writes the argument domain, which outranks anything
        // stored — so this needs no test-only code in the app itself.
        app.launchArguments = ["-albus.profile.onboarded", "NO"]
    }

    func testIBIsTheOnlyProgrammeAndReachesItsComponents() throws {
        app.launch()

        XCTAssertTrue(app.staticTexts["A few things first."].waitForExistence(timeout: 30),
                      "onboarding never appeared")

        XCTAssertFalse(app.buttons["IB"].exists,
                       "a one-option programme picker should not be shown")
        XCTAssertFalse(app.buttons["A-Level"].exists,
                       "A-Level should not be offered by the IB-only product")
        XCTAssertFalse(app.buttons["AP"].exists,
                       "AP should not be offered by the IB-only product")
        XCTAssertFalse(app.buttons["University"].exists,
                       "University should not be offered by the IB-only product")

        let subjectsTitle = app.staticTexts["Which of these do you take?"]
        let profileNext = app.buttons["Next"]
        // A cold simulator occasionally reports a synthesized accessibility
        // tap before SwiftUI receives it. Use the visible centre, like a real
        // finger, and retry only while the profile is still on screen.
        for _ in 0..<3 where !subjectsTitle.exists {
            profileNext.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if subjectsTitle.waitForExistence(timeout: 3) { break }
            guard app.staticTexts["A few things first."].exists else { break }
        }

        XCTAssertTrue(subjectsTitle.waitForExistence(timeout: 10),
                      "an IB student was not offered any subjects")

        let biology = app.buttons["Biology"]
        XCTAssertTrue(biology.exists, "Biology is missing — the bundled corpus is not reaching the UI")
        // Trust the resulting state rather than XCTest's event report. A
        // chosen subject changes the advance action from "Skip for now" to
        // "Next".
        for _ in 0..<3 where !app.buttons["Next"].exists {
            biology.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if app.buttons["Next"].waitForExistence(timeout: 2) { break }
            guard app.buttons["Skip for now"].exists else { break }
        }
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5),
                      "Biology did not become selected")
        app.buttons["Next"].tap()

        // This is what turns a generic breakdown into one shaped by the IB
        // component the student is actually preparing.
        XCTAssertTrue(app.staticTexts["WHICH SUBJECT"].waitForExistence(timeout: 10),
                      "the chosen subject was not offered on the first assignment")
        app.buttons["Biology"].tap()

        XCTAssertTrue(app.staticTexts["WHICH PART OF THE COURSE"].waitForExistence(timeout: 5),
                      "no component picker for an IB subject Albus knows")

        let component = app.buttons["Scientific investigation (SL)"]
        for _ in 0..<4 where !component.exists { app.swipeUp() }
        XCTAssertTrue(component.exists, "Biology's IB components are missing")
    }
}
