import Foundation
import SwiftData
import Testing
@testable import Albus

@MainActor
@Suite("IB context — UI and local storage")
struct IBContextUITests {

    private func store() throws -> ModelContainer {
        try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(
                schema: AlbusSchema.schema,
                isStoredInMemoryOnly: true
            )
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)!
    }

    @Test("a subject with no level round-trips as nil, never SL")
    func aMissingLevelStaysMissing() throws {
        let container = try store()
        let context = ModelContext(container)
        context.insert(Course(displayName: "Extended essay",
                              curriculumSubjectCode: "IB_DP_EXTENDED_ESSAY"))
        try context.save()

        let fresh = ModelContext(container)
        let saved = try #require(fresh.fetch(FetchDescriptor<Course>()).first)
        #expect(saved.levelRawValue == nil)
        #expect(saved.level == nil)
    }

    @Test("clearing a chosen level survives a store round-trip")
    func clearingLevelActuallyClearsIt() throws {
        let container = try store()
        let context = ModelContext(container)
        let biology = Course(displayName: "Biology",
                             curriculumSubjectCode: "IB_DP_BIOLOGY",
                             level: .hl)
        context.insert(biology)
        try context.save()

        biology.level = nil
        try context.save()

        let fresh = ModelContext(container)
        let saved = try #require(fresh.fetch(FetchDescriptor<Course>()).first)
        #expect(saved.levelRawValue == nil)
        #expect(saved.level == nil)
    }

    @Test("onboarding converts its DP choice at the write boundary")
    func onboardingChoiceProducesTheExpectedSession() {
        let now = date(2026, 9, 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current

        #expect(DiplomaYearChoice.dp2.examSession(on: now, calendar: calendar)
                == ExamSession(year: 2027, month: .may))
        #expect(DiplomaYearChoice.dp1.examSession(on: now, calendar: calendar)
                == ExamSession(year: 2028, month: .may))
    }

    @Test("TOK and the Extended Essay never acquire a level control")
    func coreSubjectsHaveNoLevel() {
        #expect(!CourseLevel.applies(to: "IB_DP_TOK"))
        #expect(!CourseLevel.applies(to: "IB_DP_EXTENDED_ESSAY"))
        #expect(CourseLevel.applies(to: "IB_DP_BIOLOGY"))
        #expect(CourseLevel.applies(to: nil))
    }

    @Test("Settings offers the next two May and November sessions")
    func settingsSessionsStayPlausible() {
        let choices = ExamSession.editableSessions(on: date(2026, 9, 1))
        #expect(choices == [
            ExamSession(year: 2026, month: .november),
            ExamSession(year: 2027, month: .may),
            ExamSession(year: 2027, month: .november),
            ExamSession(year: 2028, month: .may)
        ])
    }

    @Test("optional target points are never clamped into a false goal")
    func targetPointsValidation() {
        #expect(TargetPointsInput.value(from: "42") == 42)
        #expect(TargetPointsInput.value(from: " 45 ") == 45)
        #expect(TargetPointsInput.value(from: "0") == nil)
        #expect(TargetPointsInput.value(from: "46") == nil)
        #expect(TargetPointsInput.value(from: "fourty") == nil)
        #expect(TargetPointsInput.isValidOrEmpty(""))
    }
}
