import XCTest

/// The A-level path through onboarding, which nothing else covers.
///
/// The existing core-loop tests take the default programme (IB), and Albus has
/// no verified IB data — so they walk straight past the subject step and never
/// touch any of this. That is correct for what they test and useless for what
/// this does.
///
/// Deliberately cheap: it stops before "Build my plan", so it creates no account
/// and costs no model call. What it proves is that a student who says they do
/// A-levels is actually offered the curriculum Albus holds — the thing that was
/// broken, and that a passing build says nothing about.
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

    func testALevelStudentIsOfferedTheCurriculum() throws {
        app.launch()

        XCTAssertTrue(app.staticTexts["A few things first."].waitForExistence(timeout: 30),
                      "onboarding never appeared")

        // Before: the only qualification with verified data was the one
        // programme onboarding did not offer.
        let aLevel = app.buttons["A-Level"]
        XCTAssertTrue(aLevel.exists, "A-Level is missing from the programme list")
        aLevel.tap()

        app.buttons["Next"].tap()

        XCTAssertTrue(app.staticTexts["Which of these do you take?"].waitForExistence(timeout: 10),
                      "an A-level student was not offered any subjects")

        let biology = app.buttons["Biology"]
        XCTAssertTrue(biology.exists, "Biology is missing — the bundled corpus is not reaching the UI")
        biology.tap()
        app.buttons["Next"].tap()

        // The component picker is the whole point: this is what turns a generic
        // breakdown into one shaped by what the paper is actually worth.
        XCTAssertTrue(app.staticTexts["WHICH SUBJECT"].waitForExistence(timeout: 10),
                      "the chosen subject was not offered on the first assignment")
        app.buttons["Biology"].tap()

        XCTAssertTrue(app.staticTexts["WHICH PART OF THE COURSE"].waitForExistence(timeout: 5),
                      "no component picker for a subject Albus has a specification for")
        XCTAssertTrue(app.buttons["Paper 3"].exists, "Biology's papers are missing")
    }

    /// The other half of the same guarantee: a student on a programme Albus
    /// holds nothing for must not be shown an empty grid or an extra step.
    func testProgrammeWithoutDataSkipsTheSubjectStep() throws {
        app.launch()

        XCTAssertTrue(app.staticTexts["A few things first."].waitForExistence(timeout: 30),
                      "onboarding never appeared")

        app.buttons["University"].tap()
        app.buttons["Next"].tap()

        XCTAssertTrue(app.textFields["e.g. History term paper"].waitForExistence(timeout: 10),
                      "a programme with no curriculum data did not go straight to the deadline")
        XCTAssertFalse(app.staticTexts["WHICH SUBJECT"].exists,
                       "offered a subject picker with nothing to put in it")
    }
}
