import Testing
import SwiftData
import Foundation
@testable import Albus
import AlbusCore

/// Editing the plan, and starting a session on it.
///
/// The bug these were written for: Task detail's "Start session" button ran the
/// same closure as "Mark done". Tapping it silently completed the step instead
/// of opening Focus Mode — one-tap fake completion, in the screen that exists to
/// prevent it, in the app whose whole premise is measured time.
@MainActor
@Suite("Plan editing")
struct PlanEditingTests {

    private func makeContext() throws -> ModelContext {
        let schema = AlbusSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func fixture(_ ctx: ModelContext, steps: Int = 3) -> Assignment {
        let assignment = Assignment(title: "Essay", taskType: "essay",
                                    deadline: .now.addingTimeInterval(86_400 * 5),
                                    estimatedMinutes: 180)
        ctx.insert(assignment)
        for i in 0..<steps {
            ctx.insert(Subtask(title: "Step \(i)", ordinal: i,
                               estimatedMinutes: 60, assignment: assignment))
        }
        try? ctx.save()
        return assignment
    }

    private func ordered(_ assignment: Assignment) -> [Subtask] {
        assignment.subtasks.sorted { $0.ordinal < $1.ordinal }
    }

    // MARK: - Starting a session

    @Test("starting a session opens the block the scheduler placed")
    func startUsesThePlannedBlock() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 1)
        let step = ordered(assignment)[0]

        let planned = PlanSessionRecord(startsAt: .now.addingTimeInterval(3600),
                                        endsAt: .now.addingTimeInterval(7200),
                                        subtask: step)
        ctx.insert(planned)
        try ctx.save()

        let opened = PlanCoordinator().session(toStart: step, context: ctx)
        #expect(opened?.id == planned.id, "a new session was invented over an existing plan")
    }

    @Test("starting a session does not complete the step")
    func startNeverCompletes() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 1)
        let step = ordered(assignment)[0]

        _ = PlanCoordinator().session(toStart: step, context: ctx)

        #expect(step.completedAt == nil, "starting a session marked it done")
        #expect(step.sessions.allSatisfy { $0.measuredMinutes == nil },
                "starting a session banked time nobody spent")
    }

    @Test("a step with no placed block still gets one, rather than a dead button")
    func startCreatesWhenNoneExists() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 1)
        let step = ordered(assignment)[0]

        let opened = PlanCoordinator().session(toStart: step, context: ctx)

        #expect(opened != nil)
        #expect(opened?.subtask?.id == step.id)
        #expect(opened?.sessionState == .scheduled)
    }

    @Test("a completed block is not reopened as if it were pending")
    func finishedBlocksAreNotReused() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 1)
        let step = ordered(assignment)[0]

        let done = PlanSessionRecord(startsAt: .now.addingTimeInterval(-7200),
                                     endsAt: .now.addingTimeInterval(-3600),
                                     state: .completed, subtask: step)
        ctx.insert(done)
        try ctx.save()

        let opened = PlanCoordinator().session(toStart: step, context: ctx)
        #expect(opened?.id != done.id, "a finished session was handed back to be run again")
    }

    // MARK: - Editing

    @Test("editing a step's length changes what the scheduler is given")
    func editChangesTheEstimate() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 2)
        let step = ordered(assignment)[0]

        PlanCoordinator().updateStep(step, title: "Rewritten", minutes: 25, context: ctx)

        #expect(step.title == "Rewritten")
        #expect(step.estimatedMinutes == 25)
    }

    @Test("an absurd estimate is clamped rather than accepted")
    func editClampsDuration() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 1)
        let step = ordered(assignment)[0]
        let coordinator = PlanCoordinator()

        coordinator.updateStep(step, title: "Long", minutes: 99_999, context: ctx)
        #expect(step.estimatedMinutes == 600)

        coordinator.updateStep(step, title: "Short", minutes: -5, context: ctx)
        #expect(step.estimatedMinutes == 5)
    }

    @Test("an empty title is refused instead of blanking the step")
    func editRefusesEmptyTitle() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 1)
        let step = ordered(assignment)[0]

        PlanCoordinator().updateStep(step, title: "   ", minutes: 30, context: ctx)
        #expect(step.title == "Step 0")
    }

    @Test("deleting a step leaves the ordinals contiguous")
    func deleteRenumbers() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 4)
        let middle = ordered(assignment)[1]

        PlanCoordinator().deleteStep(middle, context: ctx)

        let remaining = ordered(assignment)
        #expect(remaining.count == 3)
        // A gap is harmless; a duplicate is not, because the scheduler places
        // work in ordinal order and ties resolve arbitrarily.
        #expect(remaining.map(\.ordinal) == [0, 1, 2])
    }

    @Test("reordering rewrites every ordinal, not just the moved one")
    func moveRenumbers() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 3)

        PlanCoordinator().moveSteps(in: assignment, from: IndexSet(integer: 2), to: 0,
                                    context: ctx)

        let titles = ordered(assignment).map(\.title)
        #expect(titles == ["Step 2", "Step 0", "Step 1"])
        #expect(ordered(assignment).map(\.ordinal) == [0, 1, 2])
    }

    @Test("adding a step reopens a finished assignment")
    func addStepReopens() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 1)
        let coordinator = PlanCoordinator()

        coordinator.setCompleted(ordered(assignment)[0], true, context: ctx)
        #expect(assignment.statusValue == .completed)

        coordinator.addStep(to: assignment, title: "One more thing", minutes: 30, context: ctx)

        #expect(assignment.subtasks.count == 2)
        // This is what frees or consumes a slot against the free-tier cap, so
        // getting it wrong is a billing-adjacent bug, not a cosmetic one.
        #expect(assignment.statusValue == .active)
    }

    @Test("the client's status vocabulary is the one the database accepts")
    func statusVocabularyMatchesTheServer() throws {
        let ctx = try makeContext()
        let assignment = fixture(ctx, steps: 1)

        PlanCoordinator().setCompleted(ordered(assignment)[0], true, context: ctx)

        // The check constraint on public.assignments allows exactly these.
        #expect(["active", "completed", "archived"].contains(assignment.status))
    }
}
