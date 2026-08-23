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
                       context: ModelContext,
                       availability: Availability = .default,
                       now: Date = .now) async {
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
            reschedule(context: context, availability: availability, now: now)
            status = .idle

        } catch let failure as PlanService.Failure {
            // The assignment survives; only the generated steps are missing.
            status = .failed(failure.errorDescription ?? "Couldn't plan that.")
        } catch {
            status = .failed("Couldn't plan that.")
        }
    }

    /// Marks a step done or undone and re-flows what is left.
    ///
    /// This is the other half of the core loop. Completing a step frees the
    /// time it was holding; un-completing it needs that time back. Either way
    /// the plan is rebuilt immediately and on device, so the student sees the
    /// consequence of the tap rather than a spinner.
    ///
    /// A completion also writes a `CompletionRecord` — estimate against actual
    /// — which is what the on-device estimator learns from. It carries
    /// durations and a task type, never the title, so the learning signal holds
    /// nothing about what the student is studying.
    func setCompleted(_ subtask: Subtask, _ completed: Bool,
                      context: ModelContext,
                      availability: Availability = .default,
                      now: Date = .now) {
        guard (subtask.completedAt != nil) != completed else { return }

        if completed {
            subtask.completedAt = now
            if let record = completionRecord(for: subtask, now: now) {
                context.insert(record)
            }
        } else {
            subtask.completedAt = nil
        }
        subtask.assignment?.updatedAt = now

        // Finishing the last step closes the assignment, which is what frees a
        // slot against the free-tier active-plan cap.
        if let assignment = subtask.assignment {
            assignment.status = assignment.isComplete ? "done" : "active"
        }

        save(context, "toggle step")
        reschedule(context: context, availability: availability, now: now)
    }

    /// Logs how long the step actually took — and only when that is known.
    ///
    /// This used to sum the *planned* length of the step's sessions and record
    /// it as the actual duration. That made every completion agree perfectly
    /// with its own estimate, so the estimator learned nothing and a student
    /// could bank a three-hour session with one tap.
    ///
    /// Now the only source is measured focus time from a real session. A step
    /// marked done without ever running one is still completed — plenty of work
    /// happens on paper, and refusing to believe the student would be worse —
    /// but it produces **no** duration sample rather than an invented one.
    /// Silence is a better input than a confident lie.
    private func completionRecord(for subtask: Subtask, now: Date) -> CompletionRecord? {
        let measured = subtask.sessions
            .filter { $0.sessionState != .skipped }
            .compactMap(\.measuredMinutes)
        guard !measured.isEmpty else { return nil }

        let total = measured.reduce(0, +)
        let interruptions = subtask.sessions.reduce(0) { $0 + ($1.interruptions ?? 0) }
        let assignment = subtask.assignment

        return CompletionRecord(
            subjectCode: assignment?.course?.displayName,
            taskType: assignment?.taskType ?? "other",
            estimatedMinutes: subtask.estimatedMinutes,
            actualMinutes: total,
            hourBucket: Calendar.current.component(.hour, from: now),
            // One uninterrupted sitting is a clean measurement. A session split
            // across app switches is still useful, just not evidence.
            highConfidence: measured.count == 1 && interruptions == 0,
            createdAt: now
        )
    }

    /// Marks blocks whose window has passed as missed, then re-flows the plan.
    ///
    /// This is the half of "Albus adapts to you" that nothing else does. The
    /// scheduler deliberately will not move a past block it was never told
    /// about — it cannot know whether that work happened — so something has to
    /// make the call. That is this: a block whose window has fully passed while
    /// its step is still incomplete is a miss, and a miss gets a new home.
    ///
    /// Cheap and idempotent: it only writes when something actually changed, so
    /// calling it on every appearance costs a fetch and nothing else.
    @discardableResult
    func sweepMissedSessions(context: ModelContext,
                             availability: Availability = .default,
                             now: Date = .now) -> Int {
        do {
            let sessions = try context.fetch(FetchDescriptor<PlanSessionRecord>())
            var missed = 0

            for session in sessions
            where session.sessionState == .scheduled
                && session.endsAt <= now
                && session.subtask?.completedAt == nil
                && !session.isFixed {
                session.sessionState = .missed
                missed += 1
            }

            guard missed > 0 else { return 0 }
            save(context, "mark missed")
            reschedule(context: context, availability: availability, now: now)
            return missed
        } catch {
            // A failed sweep must not stop the screen rendering.
            print("[Albus] missed-session sweep failed: \(error)")
            return 0
        }
    }

    /// Re-places everything that still needs time.
    ///
    /// Safe to call on any change — the scheduler pins history and moves as
    /// little as possible, so this is not a teardown.
    func reschedule(context: ModelContext,
                    availability: Availability = .default,
                    now: Date = .now) {
        do {
            let assignments = try context.fetch(FetchDescriptor<Assignment>())
            let existing = try context.fetch(FetchDescriptor<PlanSessionRecord>())
            let subtasks = try context.fetch(FetchDescriptor<Subtask>())

            let result = scheduler.schedule(
                items: PlanBridge.scheduleItems(from: assignments),
                existing: PlanBridge.plannedSessions(from: existing),
                commitments: PlanBridge.commitments(from: existing),
                availability: availability,
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
