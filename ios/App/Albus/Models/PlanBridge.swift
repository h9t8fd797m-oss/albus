import Foundation
import SwiftData
import AlbusCore

/// Converts between what is stored and what the scheduler understands.
///
/// This layer exists so `Scheduler` never imports SwiftData. Keeping the
/// scheduler on plain value types is what makes 37 tests possible without
/// standing up a model container, and it means a persistence change cannot
/// quietly alter scheduling behaviour.
enum PlanBridge {

    /// Steps still needing time. Completed work is excluded — it is history.
    ///
    /// **Where the estimator is applied.** The adjusted duration is used for
    /// *placing* the step, and the step's own `estimatedMinutes` is left alone.
    /// That split is deliberate and load-bearing: `CompletionRecord` logs the
    /// ratio of measured time against the **stored** estimate, so if the stored
    /// value were itself adjusted, every completion would feed a ratio computed
    /// against a previously-adjusted number and the correction would compound —
    /// a student 1.5x slower would drift to 2.25x, then 3.4x, until the clamp
    /// caught it. Adjusting only at the boundary keeps the learning signal
    /// measured against a fixed origin.
    ///
    /// Passing no estimator gives exactly the previous behaviour, which is what
    /// keeps the scheduler's own tests meaningful.
    static func scheduleItems(from assignments: [Assignment],
                              estimator: Estimator? = nil,
                              logs: [CompletionLog] = [],
                              now: Date = .now) -> [ScheduleItem] {
        // Every step of one assignment shares a subject and task type, so the
        // estimator's three filter passes over the whole log set would otherwise
        // be repeated once per step. Memoised on the only three inputs that can
        // change the answer.
        var cache: [Cell: Int] = [:]

        func minutes(for subtask: Subtask, in assignment: Assignment) -> Int {
            let base = subtask.estimatedMinutes
            guard let estimator, !logs.isEmpty else { return base }

            let cell = Cell(subjectCode: assignment.course?.displayName,
                            taskType: assignment.taskType, baseMinutes: base)
            if let hit = cache[cell] { return hit }

            let adjusted = estimator.estimate(
                baseMinutes: base,
                // Must match what `PlanCoordinator.completionRecord` writes, or
                // the estimate is looked up under a key nothing was logged to.
                subjectCode: assignment.course?.displayName,
                taskType: assignment.taskType,
                logs: logs, now: now
            ).minutes

            // Same bounds the plan editor enforces. The estimator can triple a
            // duration, and a step that grows past what any day can hold becomes
            // permanently unplaceable — which is a true statement about the work,
            // but 600 is where the rest of the app stops believing a single step.
            let clamped = max(5, min(600, adjusted))
            cache[cell] = clamped
            return clamped
        }

        return assignments
            .filter { $0.statusValue == .active }
            .flatMap { assignment in
                assignment.subtasks
                    .filter { $0.completedAt == nil }
                    .map { subtask in
                        ScheduleItem(
                            id: subtask.id,
                            assignmentID: assignment.id,
                            ordinal: subtask.ordinal,
                            minutes: minutes(for: subtask, in: assignment),
                            deadline: assignment.deadline,
                            priority: assignment.priorityValue.weight
                        )
                    }
            }
    }

    /// The three inputs that decide an adjusted duration.
    private struct Cell: Hashable {
        let subjectCode: String?
        let taskType: String
        let baseMinutes: Int
    }

    static func plannedSessions(from records: [PlanSessionRecord]) -> [PlannedSession] {
        records.compactMap { record in
            guard let subtask = record.subtask,
                  let assignment = subtask.assignment,
                  record.endsAt > record.startsAt,
                  !record.isFixed
            else { return nil }
            return PlannedSession(
                id: record.id,
                itemID: subtask.id,
                assignmentID: assignment.id,
                start: record.startsAt,
                end: record.endsAt,
                state: record.sessionState
            )
        }
    }

    /// Classes and anything else the student did not choose.
    static func commitments(from records: [PlanSessionRecord]) -> [FixedCommitment] {
        records
            .filter { $0.isFixed && $0.endsAt > $0.startsAt }
            .map { FixedCommitment(start: $0.startsAt, end: $0.endsAt) }
    }

    static func completionLogs(from records: [CompletionRecord]) -> [CompletionLog] {
        records.map {
            CompletionLog(
                subjectCode: $0.subjectCode,
                taskType: $0.taskType,
                estimatedMinutes: $0.estimatedMinutes,
                actualMinutes: $0.actualMinutes,
                scheduledHour: $0.hourBucket,
                completed: $0.completed,
                highConfidence: $0.highConfidence,
                at: $0.createdAt
            )
        }
    }

    /// Writes a schedule back to the store.
    ///
    /// Reconciles by session id rather than deleting and re-inserting: the
    /// scheduler preserves identity for work it merely moved, and throwing that
    /// away would turn every re-plan into a full teardown — losing the ability
    /// to animate a move, and touching rows that did not change.
    @MainActor
    static func apply(_ result: ScheduleResult,
                      to context: ModelContext,
                      subtasksByID: [UUID: Subtask],
                      existing: [PlanSessionRecord]) {
        let existingByID = Dictionary(existing.map { ($0.id, $0) },
                                      uniquingKeysWith: { a, _ in a })
        var keptIDs = Set<UUID>()

        for session in result.sessions {
            keptIDs.insert(session.id)

            if let record = existingByID[session.id] {
                // Only write when something actually changed — a no-op write
                // still dirties the object and triggers observers.
                if record.startsAt != session.start { record.startsAt = session.start }
                if record.endsAt != session.end { record.endsAt = session.end }
                if record.sessionState != session.state { record.sessionState = session.state }
            } else if let subtask = subtasksByID[session.itemID] {
                context.insert(PlanSessionRecord(
                    id: session.id,
                    startsAt: session.start,
                    endsAt: session.end,
                    state: session.state,
                    subtask: subtask
                ))
            }
        }

        // Anything scheduled that no longer appears was re-planned away.
        // Fixed commitments and history are never touched.
        for record in existing where !keptIDs.contains(record.id) {
            guard !record.isFixed, !record.sessionState.isImmutable else { continue }
            context.delete(record)
        }
    }
}
