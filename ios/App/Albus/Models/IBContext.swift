import Foundation

/// Higher or Standard level.
///
/// A subject's level is not decoration: an HL Biology internal assessment and
/// an SL one differ in the marks available, the depth expected, and therefore
/// in how the work should be broken down. Modelled as an enum rather than a
/// string so an unknown value cannot reach a generated prompt.
enum CourseLevel: String, CaseIterable, Identifiable, Sendable {
    case hl = "HL"
    case sl = "SL"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hl: "Higher level"
        case .sl: "Standard level"
        }
    }

    /// The short form, for a picker or a subject chip where the full name would
    /// crowd everything else out.
    var short: String { rawValue }
}

/// Which examination session a student is sitting, as `YYYY-MM`.
///
/// **Why this and not "DP1 / DP2".** The year is what a student knows about
/// themselves, so it is what onboarding asks for — but it is not what should be
/// stored. "DP1" is true for about twelve months and then quietly false
/// forever: the student does not re-onboard, nothing observes the academic year
/// turning over, and the stored value becomes a lie that every generated prompt
/// then repeats. The session is permanent — someone sitting May 2027 is sitting
/// May 2027 for good — so the session is stored and the year is derived.
struct ExamSession: Hashable, Sendable, Codable {
    /// 05 (May) or 11 (November). The IB has exactly two sessions a year.
    enum Month: Int, CaseIterable, Sendable, Codable {
        case may = 5
        case november = 11

        var title: String {
            switch self {
            case .may: "May"
            case .november: "November"
            }
        }
    }

    let year: Int
    let month: Month

    /// The stored form, and what the server's `^[0-9]{4}-(05|11)$` expects.
    var rawValue: String { String(format: "%04d-%02d", year, month.rawValue) }

    var title: String { "\(month.title) \(year)" }

    init(year: Int, month: Month) {
        self.year = year
        self.month = month
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]), parts[0].count == 4,
              let monthNumber = Int(parts[1]), parts[1].count == 2,
              let month = Month(rawValue: monthNumber)
        else { return nil }
        self.init(year: year, month: month)
    }
}

extension ExamSession {

    /// The Diploma year, or nil outside the two-year programme.
    ///
    /// Deliberately nil rather than clamping: a student whose session has
    /// already passed is not "DP3", and inventing a number for them is worse
    /// than admitting the programme is over. Mirrors `dp_year_for_session` in
    /// the database — if one changes, change both.
    func diplomaYear(on date: Date = .now,
                     calendar: Calendar = .current) -> Int? {
        var components = DateComponents()
        components.year = year
        components.month = month.rawValue
        components.day = 1
        guard let examMonth = calendar.date(from: components) else { return nil }

        if date > examMonth { return nil }
        guard let oneYearBefore = calendar.date(byAdding: .month, value: -12, to: examMonth),
              let twoYearsBefore = calendar.date(byAdding: .month, value: -24, to: examMonth)
        else { return nil }

        if date > oneYearBefore { return 2 }
        if date > twoYearsBefore { return 1 }
        return nil
    }

    /// The session a student in this Diploma year is sitting.
    ///
    /// Onboarding asks the question a student can answer — "which year are
    /// you in?" — and converts once, here, at the point of writing. November
    /// sessions are rarer and cannot be inferred from a date, so this assumes
    /// May and leaves November to be corrected in Settings.
    static func forDiplomaYear(_ diplomaYear: Int,
                               on date: Date = .now,
                               calendar: Calendar = .current) -> ExamSession? {
        guard diplomaYear == 1 || diplomaYear == 2 else { return nil }

        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        // The next May at or after today: this year's if it has not passed,
        // otherwise next year's.
        let nextMay = month <= Month.may.rawValue ? year : year + 1
        // DP2 sits that session; DP1 sits the one after it.
        return ExamSession(year: diplomaYear == 2 ? nextMay : nextMay + 1, month: .may)
    }
}
