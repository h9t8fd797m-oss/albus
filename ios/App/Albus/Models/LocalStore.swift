import Foundation
import SwiftData
import AlbusCore

// SwiftData models live in the app target, not in AlbusCore, so the scheduler
// and estimator stay free of persistence. They are transcribed from the
// Postgres schema rather than designed here — same names, same types, same
// nullability — because two independently-invented schemas is how a sync layer
// becomes a migration problem.

@Model
final class Course {
    #Index<Course>([\.remoteID])
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var displayName: String
    /// Stored as the token's raw value so a rename in the enum is a compile
    /// error rather than silent data corruption.
    var colorKey: String
    var courseTemplateID: UUID?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Assignment.course)
    var assignments: [Assignment] = []

    init(id: UUID = UUID(), remoteID: UUID? = nil, displayName: String,
         colorKey: Tokens.SubjectColor = .violet, courseTemplateID: UUID? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.remoteID = remoteID
        self.displayName = displayName
        self.colorKey = colorKey.rawValue
        self.courseTemplateID = courseTemplateID
        self.createdAt = createdAt
    }

    /// Subject colour is a property of the course, never of the card showing
    /// it. Views read this and never pick a colour themselves.
    var subjectColor: Tokens.SubjectColor {
        Tokens.SubjectColor(rawValue: colorKey) ?? .violet
    }
}

@Model
final class Assignment {
    #Index<Assignment>([\.deadline], [\.status])
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var title: String
    var notes: String?
    var taskType: String
    var deadline: Date
    var estimatedMinutes: Int
    var status: String
    var assessmentTypeID: UUID?
    var createdAt: Date
    var updatedAt: Date

    var course: Course?

    @Relationship(deleteRule: .cascade, inverse: \Subtask.assignment)
    var subtasks: [Subtask] = []

    init(id: UUID = UUID(), remoteID: UUID? = nil, title: String, notes: String? = nil,
         taskType: String = "other", deadline: Date, estimatedMinutes: Int,
         status: String = "active", assessmentTypeID: UUID? = nil,
         course: Course? = nil, createdAt: Date = .now) {
        self.id = id
        self.remoteID = remoteID
        self.title = title
        self.notes = notes
        self.taskType = taskType
        self.deadline = deadline
        self.estimatedMinutes = estimatedMinutes
        self.status = status
        self.assessmentTypeID = assessmentTypeID
        self.course = course
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Computed once here and read everywhere, rather than recomputed per view.
    var progress: Double {
        guard !subtasks.isEmpty else { return 0 }
        return Double(subtasks.filter { $0.completedAt != nil }.count) / Double(subtasks.count)
    }

    var isComplete: Bool {
        !subtasks.isEmpty && subtasks.allSatisfy { $0.completedAt != nil }
    }
}

@Model
final class Subtask {
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var title: String
    var guidance: String?
    var ordinal: Int
    var estimatedMinutes: Int
    var completedAt: Date?
    /// The rubric criterion this step serves, e.g. "A". Nil for general work.
    var criterionCode: String?

    var assignment: Assignment?

    @Relationship(deleteRule: .cascade, inverse: \PlanSessionRecord.subtask)
    var sessions: [PlanSessionRecord] = []

    init(id: UUID = UUID(), remoteID: UUID? = nil, title: String, guidance: String? = nil,
         ordinal: Int, estimatedMinutes: Int, criterionCode: String? = nil,
         assignment: Assignment? = nil) {
        self.id = id
        self.remoteID = remoteID
        self.title = title
        self.guidance = guidance
        self.ordinal = ordinal
        self.estimatedMinutes = estimatedMinutes
        self.criterionCode = criterionCode
        self.assignment = assignment
    }
}

@Model
final class PlanSessionRecord {
    #Index<PlanSessionRecord>([\.startsAt])
    @Attribute(.unique) var id: UUID
    var startsAt: Date
    var endsAt: Date
    var state: String
    /// Classes and other commitments the student did not choose. The scheduler
    /// routes around these and never through them.
    var isFixed: Bool

    var subtask: Subtask?

    init(id: UUID = UUID(), startsAt: Date, endsAt: Date,
         state: SessionState = .scheduled, isFixed: Bool = false,
         subtask: Subtask? = nil) {
        self.id = id
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.state = state.rawValue
        self.isFixed = isFixed
        self.subtask = subtask
    }

    var sessionState: SessionState {
        get { SessionState(rawValue: state) ?? .scheduled }
        set { state = newValue.rawValue }
    }
}

@Model
final class CompletionRecord {
    @Attribute(.unique) var id: UUID
    /// Mirrors the /logs payload exactly. Carries **no free text** — task type
    /// and durations only, never what the student was working on.
    var subjectCode: String?
    var taskType: String
    var estimatedMinutes: Int
    var actualMinutes: Int
    var hourBucket: Int?
    var minutesLate: Int?
    var highConfidence: Bool
    var completed: Bool
    var createdAt: Date
    /// False until the aggregate has been accepted by the server. Ingest is
    /// fire-and-forget, so this is what makes a retry possible.
    var synced: Bool

    init(id: UUID = UUID(), subjectCode: String?, taskType: String,
         estimatedMinutes: Int, actualMinutes: Int, hourBucket: Int? = nil,
         minutesLate: Int? = nil, highConfidence: Bool = false,
         completed: Bool = true, createdAt: Date = .now, synced: Bool = false) {
        self.id = id
        self.subjectCode = subjectCode
        self.taskType = taskType
        self.estimatedMinutes = estimatedMinutes
        self.actualMinutes = actualMinutes
        self.hourBucket = hourBucket
        self.minutesLate = minutesLate
        self.highConfidence = highConfidence
        self.completed = completed
        self.createdAt = createdAt
        self.synced = synced
    }
}
