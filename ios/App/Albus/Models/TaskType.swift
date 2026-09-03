import Foundation

/// What kind of work a task is.
///
/// **Why this type exists at all.** This list was previously written out twice
/// — a six-case enum in `OnboardingFlow` and an eight-entry array of string
/// tuples in `AddTaskSheet` — and the two had already drifted apart: onboarding
/// was quietly missing `presentation` and `other`. A student could pick a type
/// when adding a task that they could not pick during onboarding, for no
/// reason anyone chose. One list, in one place, is how that stops.
///
/// **The raw values are a wire contract**, not display strings. They are
/// checked by `assignments_task_type_check` in Postgres and by `TASK_TYPES` in
/// the breakdown Edge Function. All three lists have to agree; a value here
/// that the server does not know is a 422 the student cannot do anything
/// about. Change one, change all three.
enum TaskType: String, CaseIterable, Identifiable, Sendable, Codable {

    // The generic shapes. A student still gets set homework, and a task that
    // is genuinely just an essay should still be called one.
    case essay
    case problemSet = "problem_set"
    case labReport = "lab_report"
    case reading
    case revision
    case project
    case presentation
    case other

    // The IB assessments. Each is here because it decomposes differently, not
    // because the list looked short.
    case internalAssessment = "internal_assessment"
    case extendedEssay = "extended_essay"
    case tokEssay = "tok_essay"
    case tokExhibition = "tok_exhibition"
    case mockExam = "mock_exam"
    case finalExam = "final_exam"

    var id: String { rawValue }

    /// What the student sees. IB names are written the way students say them —
    /// "Internal assessment (IA)" rather than a formal title nobody uses.
    var title: String {
        switch self {
        case .essay:              "Essay"
        case .problemSet:         "Problem set"
        case .labReport:          "Lab report"
        case .reading:            "Reading"
        case .revision:           "Revision"
        case .project:            "Project"
        case .presentation:       "Presentation"
        case .other:              "Other"
        case .internalAssessment: "Internal assessment (IA)"
        case .extendedEssay:      "Extended essay (EE)"
        case .tokEssay:           "TOK essay"
        case .tokExhibition:      "TOK exhibition"
        case .mockExam:           "Mock exam"
        case .finalExam:          "Final exam"
        }
    }

    /// True for the six IB assessments.
    ///
    /// The planner needs this to decide whether a task has real criteria and a
    /// real deadline structure behind it, or is a piece of ordinary coursework
    /// the student named themselves.
    var isIBAssessment: Bool {
        switch self {
        case .internalAssessment, .extendedEssay,
             .tokEssay, .tokExhibition, .mockExam, .finalExam:
            true
        case .essay, .problemSet, .labReport, .reading,
             .revision, .project, .presentation, .other:
            false
        }
    }

    /// Work that is *revised for* rather than *produced*.
    ///
    /// A mock and a final exam have no deliverable — the output is what the
    /// student can recall under time pressure. Planning them means practice
    /// papers and spaced review, not drafting, so the distinction has to
    /// survive as far as the prompt.
    var isExamPreparation: Bool {
        switch self {
        case .mockExam, .finalExam: true
        default: false
        }
    }

    /// A sensible default duration, in minutes, when the student has not said.
    ///
    /// Deliberately conservative for the long IB pieces: an IA is months of
    /// work, but a *session* on it is not, and the scheduler places sessions.
    /// These are starting estimates the estimator refines from real completion
    /// data — see `AlbusCore`'s estimator — not claims about total effort.
    var defaultMinutes: Int {
        switch self {
        case .reading:                          45
        case .revision, .mockExam, .finalExam:  60
        case .problemSet, .presentation:        90
        case .essay, .labReport, .other:        120
        case .project, .tokExhibition:          150
        case .internalAssessment, .tokEssay:    180
        case .extendedEssay:                    240
        }
    }
}

extension TaskType {

    /// The types offered when a student is picking one themselves.
    ///
    /// Everything, ordered so the IB assessments come first — for an IB-only
    /// product they are the more likely answer, and burying them under
    /// "Reading" would be organising the list by the app's history rather than
    /// by what the student is looking for.
    static var offered: [TaskType] {
        allCases.sorted { lhs, rhs in
            if lhs.isIBAssessment != rhs.isIBAssessment { return lhs.isIBAssessment }
            return false          // otherwise keep declaration order
        }
    }

    /// Decoding a value the server accepted but this build does not know.
    ///
    /// Falls back rather than failing: a task the student can see and work on,
    /// minus a precise label, beats an error on a screen they cannot fix. A
    /// newer client writing `tok_exhibition` must not make the task unreadable
    /// to an older one.
    init(storedValue: String?) {
        self = storedValue.flatMap(TaskType.init(rawValue:)) ?? .other
    }
}
