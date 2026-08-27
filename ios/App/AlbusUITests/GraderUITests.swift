import XCTest

/// Drives Albus Grader against the real backend, as far as the button that
/// would spend a grading.
///
/// **The meter is the point of this file.** It read "3 left this week" directly
/// above "that's this week's markings used", because the limit that actually
/// refuses a free student is a daily cap of two and the meter was reading the
/// week. Both numbers came from the server and both were true. A unit test on
/// the binding logic proves the arithmetic; only this proves the RPC still
/// returns the shape that arithmetic is built on — which is where the last
/// three bugs in this feature lived.
///
/// Stops short of marking anything. A grading is a real Opus call and there are
/// two a day.
@MainActor
final class GraderUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testGraderMeterNamesTheWindowThatActuallyBinds() throws {
        app.launch()
        OnboardingPath.reachApp(app)

        app.buttons["Tools"].tap()

        let grader = app.staticTexts["Albus Grader"]
        XCTAssertTrue(grader.waitForExistence(timeout: 10),
                      "the pinned Albus Grader card is not on Tools")
        grader.tap()

        // "N left today" / "N left this hour" / "N left this week" / "Unlimited".
        // Any of them is a pass; the failure being guarded against is the meter
        // not resolving at all, which is what a changed RPC shape looks like
        // from here — `grading_allowance()` gained six columns and the client
        // decodes it by hand.
        let meter = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'left' OR label == 'Unlimited'")
        ).element
        XCTAssertTrue(meter.waitForExistence(timeout: 15),
                      "the allowance meter never resolved — grading_allowance() "
                      + "returned a shape the client could not decode")

        attach(app.screenshot(), named: "grader-start")

        // A free student is capped by the day, never by the week: two a day
        // against five a week means the week can only ever bind after three
        // separate days of marking.
        let label = meter.label
        XCTAssertFalse(label.contains("this week"),
                       "the meter is reading the weekly window again — it was "
                       + "showing '3 left this week' while a daily cap of two "
                       + "was the thing refusing the student. Got: \(label)")
    }

    /// The flow has to survive being walked, and it has to still be honest
    /// about a missing rubric at the point the student commits.
    func testGraderReachesTheMarkButtonAndWarnsWhenBlind() throws {
        app.launch()
        OnboardingPath.reachApp(app)

        app.buttons["Tools"].tap()
        app.staticTexts["Albus Grader"].tap()

        guard app.buttons["Grade a piece of work"].waitForExistence(timeout: 15) else {
            throw XCTSkip("out of gradings — the exhausted state is showing instead")
        }
        app.buttons["Grade a piece of work"].tap()

        // Paste something long enough to be worth marking.
        let editor = app.textViews.element(boundBy: 0)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no paste field on the work stage")
        editor.tap()
        editor.typeText(String(repeating: "The Cold War began in stages, not at once. ", count: 12))

        app.buttons["Continue"].firstMatch.tap()

        // Rubric stage: take the blind option deliberately, which is the path
        // that must never end in a grade.
        let blind = app.staticTexts["I don't have a rubric"]
        XCTAssertTrue(blind.waitForExistence(timeout: 10), "no blind option on the rubric stage")
        blind.tap()
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.buttons["Mark my work"].waitForExistence(timeout: 10),
                      "the flow never reached the marking step")

        attach(app.screenshot(), named: "grader-presentation-blind")

        // Said before the student commits, not after they have paid for it.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'no rubric'")).element.exists,
            "the blind warning is missing from the step where the student commits")
    }

    /// The other way in.
    ///
    /// There were two graders until recently — this button opened a `Form`
    /// sheet that could not upload, could not photograph a rubric and never
    /// asked how the course marks, while Tools opened the real thing. They are
    /// one flow now, and this is what proves the assignment screen actually
    /// pushes it rather than silently doing nothing: `navigationDestination`
    /// has failed quietly in this app before.
    func testMarkingFromAnAssignmentOpensTheSameGrader() throws {
        app.launch()
        OnboardingPath.reachApp(app)

        app.buttons["Home"].tap()

        let card = app.descendants(matching: .any)
            .matching(identifier: "assignmentCard").element(boundBy: 0)
        guard card.waitForExistence(timeout: 30) else {
            throw XCTSkip("no assignment on Home to open")
        }
        card.tap()

        let mark = app.buttons["markMyWork"]
        XCTAssertTrue(mark.waitForExistence(timeout: 15),
                      "the marking card is missing from the assignment screen")
        mark.tap()

        // The grader's own screen, not a sheet with a Form in it.
        XCTAssertTrue(app.navigationBars["Albus Grader"].waitForExistence(timeout: 10),
                      "marking from an assignment did not open Albus Grader")

        attach(app.screenshot(), named: "grader-from-assignment")

        // It arrives knowing what it is marking, so it starts at the work step
        // rather than asking which assignment this is.
        XCTAssertTrue(app.staticTexts["What am I marking?"].waitForExistence(timeout: 5),
                      "the grader did not carry the assignment in with it")
    }

    /// Screenshots survive the run, so a failure can be looked at rather than
    /// reasoned about from an assertion message.
    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
