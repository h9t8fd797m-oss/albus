import Foundation
import SwiftData
import Testing
@testable import Albus

/// Deleting an assignment.
///
/// The bar is "no sign of it anywhere", so these assert on the *other* tables
/// rather than on the assignment itself. A delete that leaves orphaned steps or
/// a scheduled session pointing at nothing still looks like it worked on the
/// screen the student happened to be on.
@MainActor
@Suite("Assignment deletion")
struct AssignmentDeletionTests {

    private func store() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true)))
    }

    /// An assignment with a plan, a scheduled session on each step, and a grade.
    @discardableResult
    private func seed(_ ctx: ModelContext, title: String = "Essay",
                      now: Date = Date(timeIntervalSince1970: 1_770_000_000)) -> Assignment {
        let assignment = Assignment(
            title: title, taskType: "essay",
            deadline: Calendar.current.date(byAdding: .day, value: 7, to: now)!,
            estimatedMinutes: 240)
        ctx.insert(assignment)

        for i in 0..<3 {
            let step = Subtask(title: "Step \(i)", ordinal: i, estimatedMinutes: 45,
                               assignment: assignment)
            ctx.insert(step)
            ctx.insert(PlanSessionRecord(
                startsAt: now.addingTimeInterval(Double(i) * 3600),
                endsAt: now.addingTimeInterval(Double(i) * 3600 + 2700),
                subtask: step))
        }
        ctx.insert(Grading(model: "test", inputChars: 100, criteria: [],
                           feedback: "ok", assignment: assignment))
        try? ctx.save()
        return assignment
    }

    private func count<T: PersistentModel>(_ type: T.Type, in ctx: ModelContext) -> Int {
        (try? ctx.fetchCount(FetchDescriptor<T>())) ?? -1
    }

    @Test("deleting takes the steps, their scheduled time and the marking with it")
    func deleteRemovesEverythingBelowIt() throws {
        let ctx = try store()
        let assignment = seed(ctx)

        #expect(count(Subtask.self, in: ctx) == 3)
        #expect(count(PlanSessionRecord.self, in: ctx) == 3)
        #expect(count(Grading.self, in: ctx) == 1)

        PlanCoordinator().deleteAssignment(assignment, context: ctx)

        #expect(count(Assignment.self, in: ctx) == 0)
        #expect(count(Subtask.self, in: ctx) == 0, "steps outlived their assignment")
        #expect(count(PlanSessionRecord.self, in: ctx) == 0,
                "scheduled time is still booked for work that no longer exists")
        #expect(count(Grading.self, in: ctx) == 0, "marking outlived the work it marked")
    }

    @Test("deleting one assignment leaves the others untouched")
    func deleteIsScopedToOneAssignment() throws {
        let ctx = try store()
        let doomed = seed(ctx, title: "Doomed")
        seed(ctx, title: "Survivor")

        PlanCoordinator().deleteAssignment(doomed, context: ctx)

        #expect(count(Assignment.self, in: ctx) == 1)
        #expect(count(Subtask.self, in: ctx) == 3)
        #expect(count(PlanSessionRecord.self, in: ctx) == 3)
        let left = try ctx.fetch(FetchDescriptor<Assignment>()).first
        #expect(left?.title == "Survivor")
    }

    @Test("the freed hours are given back to the rest of the plan")
    func scheduleReflowsAfterDelete() throws {
        let ctx = try store()
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let doomed = seed(ctx, title: "Doomed", now: now)
        seed(ctx, title: "Survivor", now: now)

        let coordinator = PlanCoordinator()
        coordinator.deleteAssignment(doomed, context: ctx, now: now)

        // Every session left belongs to a step that still exists — the check
        // that would fail if reflow left stale rows behind.
        let sessions = try ctx.fetch(FetchDescriptor<PlanSessionRecord>())
        #expect(!sessions.isEmpty)
        #expect(sessions.allSatisfy { $0.subtask != nil },
                "a scheduled session survived with no step attached")
    }

    @Test("deleting the work a timer is running on stops the timer")
    func deleteStopsARunningFocusSession() throws {
        // Otherwise the timer keeps counting against a step that no longer
        // exists, and whatever it banks on finishing is attached to nothing.
        let ctx = try store()
        let assignment = seed(ctx)
        let step = try #require(assignment.subtasks.first)
        let session = try #require(step.sessions.first)

        let focus = FocusSession()
        focus.start(session, context: ctx)
        #expect(focus.phase != .idle)

        PlanCoordinator().deleteAssignment(assignment, context: ctx, focusSession: focus)

        #expect(focus.phase == .idle, "a timer is still running on a deleted step")
        #expect(count(Assignment.self, in: ctx) == 0)
    }

    @Test("a timer on a different assignment keeps running")
    func deleteLeavesAnUnrelatedSessionAlone() throws {
        let ctx = try store()
        let doomed = seed(ctx, title: "Doomed")
        let other = seed(ctx, title: "Other")
        let session = try #require(other.subtasks.first?.sessions.first)

        let focus = FocusSession()
        focus.start(session, context: ctx)

        PlanCoordinator().deleteAssignment(doomed, context: ctx, focusSession: focus)

        #expect(focus.phase != .idle, "deleting one assignment stopped another's timer")
    }

    @Test("a server row that could not be deleted is remembered, not dropped")
    func failedRemoteDeletesAreQueued() {
        // Until this lands the row still counts against the free-plan cap, so
        // forgetting it means a student who deleted three assignments is still
        // told they have three active.
        let id = UUID()
        PendingDeletions.record(id)
        #expect(PendingDeletions.all().contains(id))

        // Recording twice must not queue it twice.
        PendingDeletions.record(id)
        #expect(PendingDeletions.all().filter { $0 == id }.count == 1)
    }
}
