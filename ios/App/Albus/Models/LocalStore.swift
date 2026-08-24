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
    /// One of `AssignmentPriority`. Stored raw so a rename in the enum is a
    /// compile error here rather than a silent migration.
    ///
    /// Defaulted in the declaration, not just the initialiser: SwiftData needs a
    /// value for rows written before this column existed.
    var priority: String = AssignmentPriority.normal.rawValue
    var assessmentTypeID: UUID?
    var createdAt: Date
    var updatedAt: Date

    var course: Course?
    /// The rubric this is marked against. Nil is normal — plenty of work has no
    /// rubric, and refusing to plan without one would be worse than planning
    /// without one.
    var rubric: Rubric?

    @Relationship(deleteRule: .cascade, inverse: \Subtask.assignment)
    var subtasks: [Subtask] = []

    init(id: UUID = UUID(), remoteID: UUID? = nil, title: String, notes: String? = nil,
         taskType: String = "other", deadline: Date, estimatedMinutes: Int,
         status: AssignmentStatus = .active,
         priority: AssignmentPriority = .normal,
         assessmentTypeID: UUID? = nil,
         course: Course? = nil, rubric: Rubric? = nil, createdAt: Date = .now) {
        self.id = id
        self.remoteID = remoteID
        self.title = title
        self.notes = notes
        self.taskType = taskType
        self.deadline = deadline
        self.estimatedMinutes = estimatedMinutes
        self.status = status.rawValue
        self.priority = priority.rawValue
        self.assessmentTypeID = assessmentTypeID
        self.course = course
        self.rubric = rubric
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

    var priorityValue: AssignmentPriority {
        get { AssignmentPriority(rawValue: priority) ?? .normal }
        set { priority = newValue.rawValue }
    }

    var statusValue: AssignmentStatus {
        get { AssignmentStatus(rawValue: status) ?? .active }
        set { status = newValue.rawValue }
    }
}

/// How urgent the student says this is.
///
/// Three values, not a slider. A 1-10 scale invites marking everything an 8,
/// and a scheduler cannot act on a distinction the student did not really make.
enum AssignmentPriority: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, normal, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    /// Higher sorts earlier. Only ever breaks a tie between two pieces of work
    /// competing for the same window — never overrides a deadline.
    var weight: Int {
        switch self {
        case .high: 2
        case .normal: 1
        case .low: 0
        }
    }
}

/// The assignment lifecycle, in the vocabulary the database actually accepts.
///
/// This was a loose string, and the client wrote `"done"` where the server's
/// check constraint allows only `active`/`completed`/`archived`. Nothing broke
/// yet because status is not synced — which is exactly the kind of bug that
/// waits for the feature that would have shipped it.
enum AssignmentStatus: String, CaseIterable, Codable, Sendable {
    case active, completed, archived
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

    // ── What actually happened ────────────────────────────────────────────
    // `startsAt`/`endsAt` are the *plan*. These three are the *record*, and
    // they are what the estimator learns from. Keeping them separate is what
    // stops "I marked it done" being mistaken for "I did it".
    //
    // All optional so an existing store migrates without losing anything.

    /// When a focus session was actually begun.
    var startedAt: Date?
    /// When it actually ended — by running out, or by being ended early.
    var endedAt: Date?
    /// Seconds genuinely spent in a running focus session, accumulated across
    /// pauses. Measured with a monotonic clock, so moving the device clock
    /// forward does not manufacture focus time.
    var focusedSeconds: Int?
    /// How many times the app was backgrounded mid-session. Not a punishment —
    /// it is the honest caveat on a session's duration.
    var interruptions: Int?

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

    /// How long the session was planned to run.
    var plannedSeconds: Int {
        max(0, Int(endsAt.timeIntervalSince(startsAt)))
    }

    /// Measured focus, in whole minutes. Nil when the session was never run —
    /// which is different from zero, and must stay different: an unrun session
    /// has no measurement, and guessing one would poison the estimator.
    var measuredMinutes: Int? {
        guard let focusedSeconds, focusedSeconds > 0 else { return nil }
        return max(1, focusedSeconds / 60)
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

// MARK: - Rubrics

/// A rubric the student owns, saves once and reuses.
///
/// Two ways in, because both are real. Most students have a rubric as a block of
/// text on the assignment sheet — that is `body`, and it is enough to grade
/// against. Some want it broken into criteria they can see marks against — those
/// are `items`. Grading prefers items and falls back to the body, so pasting
/// works immediately and structure is an upgrade rather than a requirement.
@Model
final class Rubric {
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var name: String
    /// `custom` when pasted, `template` when copied from curriculum data.
    var source: String
    var assessmentTypeID: UUID?
    /// The pasted sheet. Capped at the same 8000 characters the server enforces,
    /// so a rubric that saves locally is one the server will also accept.
    var body: String?
    var totalMarks: Int?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RubricItem.rubric)
    var items: [RubricItem] = []

    /// Assignments pointing here. Nullify rather than cascade: deleting a rubric
    /// must never delete the student's work, only the link to it.
    @Relationship(deleteRule: .nullify, inverse: \Assignment.rubric)
    var assignments: [Assignment] = []

    static let maxBodyCharacters = 8000
    static let maxItems = 40

    init(id: UUID = UUID(), remoteID: UUID? = nil, name: String,
         source: RubricSource = .custom, assessmentTypeID: UUID? = nil,
         body: String? = nil, totalMarks: Int? = nil, createdAt: Date = .now) {
        self.id = id
        self.remoteID = remoteID
        self.name = name
        self.source = source.rawValue
        self.assessmentTypeID = assessmentTypeID
        self.body = body
        self.totalMarks = totalMarks
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var sortedItems: [RubricItem] {
        items.sorted { $0.ordinal < $1.ordinal }
    }

    /// Marks the student can actually be scored out of: the declared total when
    /// there is one, otherwise the sum of the criteria.
    var effectiveTotalMarks: Int? {
        if let totalMarks { return totalMarks }
        let summed = items.compactMap(\.marks).reduce(0, +)
        return summed > 0 ? summed : nil
    }

    /// A rubric with neither criteria nor text cannot ground anything, and
    /// grading against it would be a confident guess. The UI refuses to save one.
    var isUsable: Bool {
        !items.isEmpty || !(body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summary: String {
        if !items.isEmpty {
            let marks = effectiveTotalMarks.map { " · \($0) marks" } ?? ""
            return "\(items.count) criteria\(marks)"
        }
        return "Pasted rubric"
    }
}

enum RubricSource: String, CaseIterable, Codable, Sendable {
    /// Pasted or typed by the student.
    case custom
    /// Copied out of curriculum reference data and then owned by the student.
    case template
}

@Model
final class RubricItem {
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    /// The criterion letter or number, e.g. "A". Nil when the rubric does not
    /// use codes.
    var code: String?
    var name: String
    var marks: Int?
    var guidance: String?
    var ordinal: Int

    var rubric: Rubric?

    init(id: UUID = UUID(), remoteID: UUID? = nil, code: String? = nil,
         name: String, marks: Int? = nil, guidance: String? = nil,
         ordinal: Int, rubric: Rubric? = nil) {
        self.id = id
        self.remoteID = remoteID
        self.code = code
        self.name = name
        self.marks = marks
        self.guidance = guidance
        self.ordinal = ordinal
        self.rubric = rubric
    }

    /// "A · Knowledge" or just "Knowledge".
    var displayName: String {
        guard let code, !code.isEmpty else { return name }
        return "\(code) · \(name)"
    }
}
