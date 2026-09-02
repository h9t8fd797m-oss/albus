import Foundation

/// The answer onboarding asks for, never a persisted fact.
///
/// The durable value is the examination session produced by `examSession`.
/// Keeping this type beside the UI avoids accidentally adding a DP year to
/// Preferences or SwiftData, where it would become false at the next rollover.
enum DiplomaYearChoice: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case dp1 = 1
    case dp2 = 2

    var id: Int { rawValue }
    var title: String { "DP\(rawValue)" }

    func examSession(on date: Date = .now,
                     calendar: Calendar = .current) -> ExamSession? {
        ExamSession.forDiplomaYear(rawValue, on: date, calendar: calendar)
    }
}

extension ExamSession {
    /// The four sessions a current student could plausibly be working toward:
    /// the next two May sessions and the next two November sessions.
    ///
    /// Returned chronologically so the Settings picker reads like a timeline.
    static func editableSessions(on date: Date = .now,
                                 calendar: Calendar = .current) -> [ExamSession] {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let firstMay = month <= Month.may.rawValue ? year : year + 1
        let firstNovember = month <= Month.november.rawValue ? year : year + 1

        return [
            ExamSession(year: firstMay, month: .may),
            ExamSession(year: firstMay + 1, month: .may),
            ExamSession(year: firstNovember, month: .november),
            ExamSession(year: firstNovember + 1, month: .november)
        ]
        .sorted { $0.rawValue < $1.rawValue }
    }
}

extension CourseLevel {
    /// TOK and the Extended Essay are Diploma core, not HL/SL subjects.
    /// Everything else may keep an unknown (nil) level, but can be assigned one.
    static func applies(to curriculumSubjectCode: String?) -> Bool {
        switch curriculumSubjectCode {
        case "IB_DP_TOK", "IB_DP_EXTENDED_ESSAY": false
        default: true
        }
    }
}

/// Parsing shared by onboarding and Settings. Invalid optional input remains
/// visibly invalid; it is never coerced to 1 or 45 and never sent to the server.
enum TargetPointsInput {
    static func value(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...45).contains(value) else { return nil }
        return value
    }

    static func isValidOrEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value(from: text) != nil
    }
}
