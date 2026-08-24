import Testing
import SwiftData
import Foundation
@testable import Albus
import AlbusCore

/// The rules that stop a session being faked.
///
/// A student can only ever lie to themselves here — none of this is a security
/// boundary — but the estimator is the product, and it is only as good as its
/// input. Completion used to bank a full session's worth of work in one tap,
/// which meant every estimate agreed with itself and nothing was ever learned.
@MainActor
@Suite("Session honesty")
struct SessionHonestyTests {

    private func makeContext() throws -> ModelContext {
        let schema = AlbusSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// One assignment, one 60-minute step, one session planned for it.
    private func fixture(_ ctx: ModelContext) -> (Subtask, PlanSessionRecord) {
        let assignment = Assignment(title: "Essay", taskType: "essay",
                                    deadline: .now.addingTimeInterval(86_400 * 3),
                                    estimatedMinutes: 60)
        let step = Subtask(title: "Write the outline", ordinal: 0,
                           estimatedMinutes: 60, assignment: assignment)
        let session = PlanSessionRecord(startsAt: .now.addingTimeInterval(3600),
                                        endsAt: .now.addingTimeInterval(7200),
                                        subtask: step)
        ctx.insert(assignment); ctx.insert(step); ctx.insert(session)
        try? ctx.save()
        return (step, session)
    }

    @Test("a step marked done without a session logs no duration")
    func tappingDoneBanksNothing() throws {
        let ctx = try makeContext()
        let (step, _) = fixture(ctx)

        PlanCoordinator().setCompleted(step, true, context: ctx)

        // Completed, because plenty of work happens on paper and refusing to
        // believe the student would be worse.
        #expect(step.completedAt != nil)
        // But nothing was measured, so nothing is claimed.
        let logs = try ctx.fetch(FetchDescriptor<CompletionRecord>())
        #expect(logs.isEmpty, "a tap invented \(logs.count) duration sample(s)")
    }

    @Test("the planned length is never mistaken for the measured one")
    func plannedIsNotMeasured() throws {
        let ctx = try makeContext()
        let (step, session) = fixture(ctx)

        // Ran for four minutes of a sixty-minute plan.
        session.focusedSeconds = 4 * 60
        session.startedAt = .now
        session.endedAt = .now

        PlanCoordinator().setCompleted(step, true, context: ctx)

        let logs = try ctx.fetch(FetchDescriptor<CompletionRecord>())
        #expect(logs.count == 1)
        let log = try #require(logs.first)
        #expect(log.actualMinutes == 4, "recorded \(log.actualMinutes) minutes for a 4-minute sitting")
        #expect(log.estimatedMinutes == 60)
    }

    @Test("an unrun session measures nothing, which is not the same as zero")
    func unrunHasNoMeasurement() throws {
        let ctx = try makeContext()
        let (_, session) = fixture(ctx)

        #expect(session.measuredMinutes == nil)
        session.focusedSeconds = 0
        #expect(session.measuredMinutes == nil, "zero focus must not read as a measurement")
        session.focusedSeconds = 30      // half a minute still counts as a minute
        #expect(session.measuredMinutes == 1)
    }

    @Test("a session interrupted by leaving the app is recorded as lower confidence")
    func interruptionsLowerConfidence() throws {
        let ctx = try makeContext()
        let (step, session) = fixture(ctx)
        session.focusedSeconds = 45 * 60
        session.interruptions = 3

        PlanCoordinator().setCompleted(step, true, context: ctx)

        let log = try #require(try ctx.fetch(FetchDescriptor<CompletionRecord>()).first)
        #expect(log.actualMinutes == 45)
        #expect(log.highConfidence == false)
    }

    @Test("one clean sitting is high confidence")
    func cleanSittingIsConfident() throws {
        let ctx = try makeContext()
        let (step, session) = fixture(ctx)
        session.focusedSeconds = 58 * 60
        session.interruptions = 0

        PlanCoordinator().setCompleted(step, true, context: ctx)

        let log = try #require(try ctx.fetch(FetchDescriptor<CompletionRecord>()).first)
        #expect(log.highConfidence)
    }

    @Test("completion logs still carry no free text")
    func logsCarryNoContent() throws {
        let ctx = try makeContext()
        let (step, session) = fixture(ctx)
        session.focusedSeconds = 10 * 60

        PlanCoordinator().setCompleted(step, true, context: ctx)

        let log = try #require(try ctx.fetch(FetchDescriptor<CompletionRecord>()).first)
        // The title must never reach the learning signal.
        #expect(log.taskType == "essay")
        #expect(log.subjectCode == nil)
    }

    @Test("marking a step undone does not delete the measurement")
    func undoKeepsHistory() throws {
        let ctx = try makeContext()
        let (step, session) = fixture(ctx)
        session.focusedSeconds = 12 * 60

        let coordinator = PlanCoordinator()
        coordinator.setCompleted(step, true, context: ctx)
        coordinator.setCompleted(step, false, context: ctx)

        #expect(step.completedAt == nil)
        // The time was really spent, whatever the step's status now says.
        #expect(session.measuredMinutes == 12)
    }
}
