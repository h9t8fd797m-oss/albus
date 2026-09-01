import XCTest

/// A real account-and-RPC proof for the IB context collected in onboarding.
///
/// Opt-in because the normal app configuration points at production. This test
/// must only run with build settings redirected to local Supabase; otherwise it
/// skips before launching and cannot create an account or consume paid AI.
@MainActor
final class IBContextOnboardingUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-albus.profile.onboarded", "NO"]
    }

    func testDP2BiologyHLAndMathsAASLReachTheServer() throws {
        let localRun = Bundle(for: IBContextOnboardingUITests.self)
            .object(forInfoDictionaryKey: "ALBUS_LOCAL_CONTEXT_TEST") as? String
        guard localRun == "1" else {
            throw XCTSkip("Runs only against the isolated local Supabase stack")
        }

        app.launch()
        XCTAssertTrue(app.staticTexts["A few things first."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["DP2"].isSelected, "DP2 is not the onboarding default")

        let points = app.textFields["Out of 45"]
        XCTAssertTrue(points.exists)
        points.tap()
        points.typeText("38")

        let subjectsTitle = app.staticTexts["Which of these do you take?"]
        tap(app.buttons["Next"], until: subjectsTitle)
        XCTAssertTrue(subjectsTitle.waitForExistence(timeout: 10))

        selectSubject(named: "Biology")
        selectSubject(named: "Mathematics: analysis and approaches")

        let biologyHL = app.buttons["onboardingLevel.IB_DP_BIOLOGY.HL"]
        scrollTo(biologyHL)
        XCTAssertTrue(biologyHL.exists, "Biology did not get a level row")
        biologyHL.tap()

        let mathsSL = app.buttons["onboardingLevel.IB_DP_MATHS_AA.SL"]
        scrollTo(mathsSL)
        XCTAssertTrue(mathsSL.exists, "Maths AA did not get a level row")
        mathsSL.tap()

        let deadlineField = app.textFields["e.g. History term paper"]
        tap(app.buttons["Next"], until: deadlineField)
        XCTAssertTrue(deadlineField.waitForExistence(timeout: 10))
        deadlineField.tap()
        deadlineField.typeText("Local IB context proof")

        app.buttons["Build my plan"].tap()
        let done = app.buttons["Show me"]
        XCTAssertTrue(done.waitForExistence(timeout: 90),
                      "onboarding never completed its local account and profile writes")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "IB context saved through onboarding"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func selectSubject(named name: String) {
        let subject = app.buttons[name]
        scrollTo(subject)
        XCTAssertTrue(subject.exists, "\(name) is missing from IB subjects")
        subject.tap()
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }

    /// Retry only while the destination is absent. XCTest occasionally reports
    /// a synthesized tap before a cold SwiftUI app receives it.
    private func tap(_ button: XCUIElement, until destination: XCUIElement) {
        for _ in 0..<3 where !destination.exists {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if destination.waitForExistence(timeout: 3) { break }
        }
    }
}
