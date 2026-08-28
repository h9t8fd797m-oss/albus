import XCTest

/// Getting a fresh install as far as the app.
///
/// One copy, because there were two and they went stale together: both tapped
/// "Next" exactly once and then expected the deadline field, which stopped
/// being true the day onboarding gained a subject-picker step between them.
/// Every UI test in this target failed on the same line for a reason that had
/// nothing to do with what any of them was testing.
///
/// So this walks the flow rather than counting screens: whatever advance button
/// is on screen gets tapped until the one step that needs typing appears. A
/// sixth step added tomorrow costs nothing here.
@MainActor
enum OnboardingPath {

    /// Titles that mean "carry on" at some step of onboarding. The subject
    /// picker offers "Skip for now" until something is selected, and offering a
    /// student a step they have nothing to say to is the point of it.
    private static let advanceTitles = ["Next", "Skip for now", "Continue"]

    static func reachApp(_ app: XCUIApplication, file: StaticString = #filePath,
                         line: UInt = #line) {
        let home = app.buttons["Home"]        // present in the app, absent in onboarding
        let onboarding = app.staticTexts["A few things first."]

        // Whichever appears first decides the path. An install that already has
        // a session never sees onboarding at all.
        let start = Date()
        while Date().timeIntervalSince(start) < 25 {
            if home.exists { return }
            if onboarding.exists { break }
            usleep(200_000)
        }
        guard onboarding.exists else {
            XCTAssertTrue(home.waitForExistence(timeout: 20),
                          "neither onboarding nor the app appeared", file: file, line: line)
            return
        }

        let deadlineField = app.textFields["e.g. History term paper"]

        // Bounded so a flow that stops advancing fails as a test rather than
        // hanging until the whole scheme times out.
        for _ in 0..<8 {
            if deadlineField.exists { break }
            guard let advance = advanceTitles.lazy
                .map({ app.buttons[$0] })
                .first(where: { $0.exists && $0.isHittable })
            else {
                usleep(300_000)
                continue
            }
            advance.tap()
            usleep(400_000)
        }

        XCTAssertTrue(deadlineField.waitForExistence(timeout: 15),
                      "onboarding never reached the deadline step", file: file, line: line)
        deadlineField.tap()
        deadlineField.typeText("Onboarding first assignment")

        app.buttons["Build my plan"].tap()

        // Account creation plus a real Claude call.
        let done = app.buttons["Show me"]
        XCTAssertTrue(done.waitForExistence(timeout: 120),
                      "onboarding never finished — account creation or the first plan failed",
                      file: file, line: line)
        done.tap()

        // Generous, and measured rather than guessed: tapping "Show me" is
        // followed by the first store write, the first sync and the tab bar's
        // own appearance, and on a cold simulator that ran past twenty seconds
        // and failed a test about something else entirely.
        XCTAssertTrue(home.waitForExistence(timeout: 60),
                      "onboarding completed but the app never appeared", file: file, line: line)
    }
}
