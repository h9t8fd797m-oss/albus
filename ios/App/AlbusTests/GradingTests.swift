import Testing
import Foundation
@testable import Albus
import AlbusCore

/// The two things a grading has to get right before anything else is worth
/// building on it: what it says is left, and what it says the grade is.
///
/// Both were wrong in ways every existing test was green through, which is why
/// these are written against the reported symptom rather than the code path.
@Suite("Grading allowance")
struct GradingAllowanceTests {

    /// The bug as reported: "the app says all weekly gradings have been used,
    /// even though only one has been used this week."
    ///
    /// A free student gets two a day and five a week. After two in one evening
    /// the *day* is what stops them — but the meter read the week, so the
    /// screen showed "3 left this week" directly above "that's this week's
    /// markings used". Both numbers were true. Together they were nonsense.
    @Test("the window that binds is the one that will actually refuse them")
    func bindingIsTheTighterWindow() {
        let allowance = GradingService.Allowance(
            usedHour: 2, limitHour: 2,
            usedDay: 2, limitDay: 2,
            usedWeek: 2, limitWeek: 5
        )

        #expect(allowance.hasAny == false)
        #expect(allowance.remaining == 0)
        // Not the week — the week still has three in it.
        #expect(allowance.binding.window == .day)
    }

    /// A student who has marked one draft today has one left today, not four
    /// left this week. The larger number is true and useless: they cannot spend
    /// it.
    @Test("a partly used day reports the day, not the week")
    func partlyUsedDay() {
        let allowance = GradingService.Allowance(
            usedHour: 1, limitHour: 2,
            usedDay: 1, limitDay: 2,
            usedWeek: 1, limitWeek: 5
        )

        #expect(allowance.remaining == 1)
        #expect(allowance.binding.window == .day)
        #expect(allowance.hasAny)
    }

    /// Ties break toward the longer window, and this is the reason: at zero on
    /// both the hour and the day, naming the hour promises a grading back in
    /// sixty minutes that the daily cap will refuse to hand over.
    @Test("a tie names the window that takes longest to lift")
    func tieBreaksLong() {
        let inAnHour = Date.now.addingTimeInterval(3_600)
        let tomorrow = Date.now.addingTimeInterval(86_400)

        let allowance = GradingService.Allowance(
            usedHour: 2, limitHour: 2,
            usedDay: 2, limitDay: 2,
            usedWeek: 2, limitWeek: 5,
            hourResetsAt: inAnHour, dayResetsAt: tomorrow
        )

        #expect(allowance.binding.window == .day)
        #expect(allowance.binding.resetsAt == tomorrow)
    }

    /// The live endpoint refuses on the hour before it looks at the day, so a
    /// free student who has used two is told "hourly" by the server while the
    /// day is equally gone. The screen takes the window from the allowance
    /// instead, which is why the two can never contradict each other on the
    /// same page.
    @Test("both windows empty resolves to the one that lasts longer")
    func hourAndDayBothEmpty() {
        let allowance = GradingService.Allowance(
            usedHour: 2, limitHour: 2,
            usedDay: 2, limitDay: 2,
            usedWeek: 2, limitWeek: 5
        )
        #expect(allowance.binding.window == .day)
        #expect(GradingService.Failure.usedUp(allowance.binding.window)
                == .usedUp(.day))
    }

    /// Plus reports a weekly limit of zero, meaning "no ceiling". Reading that
    /// as "none left" would tell a paying student they had run out.
    @Test("no weekly ceiling is not an empty weekly allowance")
    func plusHasNoWeeklyCeiling() {
        let allowance = GradingService.Allowance(
            usedHour: 0, limitHour: 6,
            usedDay: 9, limitDay: 20,
            usedWeek: 40, limitWeek: 0,
            isPlus: true
        )

        #expect(allowance.hasAny)
        #expect(allowance.binding.window == .hour)
        #expect(allowance.binding.limit == 6)
    }

    /// A student capped by nothing at all still has to render.
    @Test("an uncapped student is not out of gradings")
    func uncapped() {
        let allowance = GradingService.Allowance(
            usedHour: 3, limitHour: 0,
            usedDay: 9, limitDay: 0,
            usedWeek: 40, limitWeek: 0,
            isPlus: true
        )

        #expect(allowance.hasAny)
        #expect(allowance.remaining == nil)
    }

    /// Postgres writes microseconds and a two-digit offset. `ISO8601DateFormatter`
    /// needs `.withFractionalSeconds` for the first and `+00:00` for the second,
    /// and each configuration rejects the other's output — so a single formatter
    /// silently drops every reset time that lands on a whole second.
    @Test("both shapes of Postgres timestamp parse")
    func timestampVariants() {
        let withFraction = GradingService.Allowance.timestamp("2026-08-27T19:25:50.064319+00:00")
        let whole = GradingService.Allowance.timestamp("2026-08-27T19:25:50+00:00")
        let shortOffset = GradingService.Allowance.timestamp("2026-08-27T19:25:50.064319+00")

        #expect(withFraction != nil)
        #expect(whole != nil)
        #expect(shortOffset != nil)
        #expect(GradingService.Allowance.timestamp(nil) == nil)
        #expect(GradingService.Allowance.timestamp("not a date") == nil)
    }
}

@MainActor
@Suite("The final grade")
struct FinalGradeTests {

    private func grading(basis: GradingBasis, label: String?,
                         marks: Int? = nil, total: Int? = nil) -> Grading {
        Grading(model: "claude-opus-5", inputChars: 3_000,
                overallMarks: marks, totalMarks: total,
                gradeLabel: label, gradeNote: label == nil ? nil : "A note.",
                feedback: "…", basis: basis)
    }

    /// The reported bug: "it gives feedback but no final grade."
    ///
    /// The screen only ever had `overall_marks/total_marks` to show, which is
    /// the rubric's arithmetic — an MYP rubric totals 32, and "0/32" is not
    /// what a course puts on the work.
    @Test("the grade is what leads, not the rubric's arithmetic")
    func gradeLeads() {
        let marked = grading(basis: .personal, label: "4", marks: 17, total: 32)

        #expect(marked.headline == "4")
        #expect(marked.headlineIsGrade)
        // The marks still show, beside it rather than instead of it.
        #expect(marked.scoreText == "17/32")
    }

    /// The model is asked for a label and usually gives one. "Usually" is not
    /// good enough for the single number the student opened the app for.
    @Test("marks stand in when no grade was named")
    func marksAreTheFallback() {
        let marked = grading(basis: .personal, label: nil, marks: 17, total: 32)

        #expect(marked.headline == "17/32")
        // Not a grade in their scale, and not dressed up as one.
        #expect(marked.headlineIsGrade == false)
    }

    /// A blind reading has no rubric behind it. Anything in the headline slot
    /// is read as a grade whatever banner sits above it, so there is nothing in
    /// the headline slot.
    @Test("a blind reading has no headline at all")
    func blindHasNoHeadline() {
        let read = grading(basis: .blind, label: nil)
        #expect(read.headline == nil)

        // Even if a label somehow survived the server's stripping, the client
        // refuses it a second time. Two independent guards, because this is the
        // one thing the feature must never do.
        let forged = grading(basis: .blind, label: "A-", marks: 18, total: 20)
        #expect(forged.headline == nil)
    }

    /// A rubric that carries no marks is a real case, and rendering it as "0"
    /// would be a lie about the work.
    @Test("a rubric with no marks has no headline either")
    func commentOnlyRubric() {
        let marked = grading(basis: .personal, label: nil)
        #expect(marked.headline == nil)
    }

    /// History rows are the only place a grading can be identified: the work
    /// itself is deliberately never stored.
    @Test("every grading can be named in a list")
    func displayTitleIsNeverEmpty() {
        let named = Grading(model: "m", inputChars: 900, workTitle: "Bio IA draft",
                            feedback: "…", basis: .personal)
        #expect(named.displayTitle == "Bio IA draft")

        let loose = Grading(model: "m", inputChars: 900, feedback: "…", basis: .blind)
        #expect(loose.displayTitle.isEmpty == false)
    }
}
