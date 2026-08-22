import Foundation
import SwiftData
import AlbusCore

/// The core loop, in one place: an assignment goes in, a placed plan comes out.
///
///   backend breakdown  →  local persistence  →  scheduler  →  visible plan
///
/// The steps come from the server (it holds the key and enforces the quota).
/// Placing them in time is done here, on device, because a miss has to re-flow
/// instantly and offline — that is the whole product, and it cannot depend on
/// a round trip.
@Observable
@MainActor
final class PlanCoordinator {

    enum Status: Equatable {
        case idle
        case planning
        case failed(String)
    }

    private(set) var status: Status = .idle

    private let plans: PlanService
    private let scheduler = Scheduler()

    init(plans: PlanService = PlanService()) {
        self.plans = plans
    }

    /// Adds an assignment and returns with its plan placed in time.
    ///
    /// The assignment is saved *before* the network call. If generation fails
    /// the student keeps their work and a deadline, which is the difference
    /// between a slow moment and losing what they typed.
    func addAssignment(title: String, taskType: String, deadline: Date,
                       estimatedMinutes: Int, course: Course?,
                       context: ModelContext, now: Date = .now) async {
        status = .planning

        let assignment = Assignment(
            title: title, taskType: taskType, deadline: deadline,
            estimatedMinutes: estimatedMinutes, course: course
        )
        context.insert(assignment)
        save(context, "insert assignment")

        do {
            let result = try await plans.breakdown(
                title: title, taskType: taskType,
                deadline: deadline, estimatedMinutes: estimatedMinutes
            )

            // Server-assigned id, so a later sync can match rows rather than
            // guessing by title.
            assignment.remoteID = result.assignmentID

            for (i, step) in result.steps.enumerated() {
                context.insert(Subtask(
                    title: step.title,
                    guidance: step.guidance.isEmpty ? nil : step.guidance,
                    ordinal: i,
                    estimatedMinutes: step.estimatedMinutes,
                    criterionCode: step.criterionCode,
                    assignment: assignment
                ))
            }
            save(context, "insert steps")
            reschedule(context: context, now: now)
            status = .idle

        } catch let failure as PlanService.Failure {
            // The assignment survives; only the generated steps are missing.
            status = .failed(failure.errorDescription ?? "Couldn't plan that.")
        } catch {
            status = .failed("Couldn't plan that.")
        }
    }

    /// Re-places everything that still needs time.
    ///
    /// Safe to call on any change — the scheduler pins history and moves as
    /// little as possible, so this is not a teardown.
    func reschedule(context: ModelContext, now: Date = .now) {
        do {
            let assignments = try context.fetch(FetchDescriptor<Assignment>())
            let existing = try context.fetch(FetchDescriptor<PlanSessionRecord>())
            let subtasks = try context.fetch(FetchDescriptor<Subtask>())

            let result = scheduler.schedule(
                items: PlanBridge.scheduleItems(from: assignments),
                existing: PlanBridge.plannedSessions(from: existing),
                commitments: PlanBridge.commitments(from: existing),
                now: now
            )

            PlanBridge.apply(
                result, to: context,
                subtasksByID: Dictionary(subtasks.map { ($0.id, $0) },
                                         uniquingKeysWith: { a, _ in a }),
                existing: existing
            )
            save(context, "apply schedule")
        } catch {
            status = .failed("Couldn't rebuild your plan.")
        }
    }

    private func save(_ context: ModelContext, _ what: String) {
        do { try context.save() } catch {
            // Losing a write silently is worse than a visible failure.
            status = .failed("Couldn't save.")
            print("save failed during \(what): \(error)")
        }
    }
}
