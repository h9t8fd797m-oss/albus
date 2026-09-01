import Testing
import Foundation
@testable import Albus

/// The exam session is stored and the Diploma year is derived from it. These
/// tests exist because that decision only pays off if the derivation is right
/// at the boundaries — the whole point was to stop a stored "DP1" from going
/// quietly stale, which is not an improvement if the replacement is wrong.
@Suite("IB context — exam session and derived Diploma year")
struct IBContextTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)!
    }

    // MARK: - Round-tripping

    @Test("a session round-trips through its stored form")
    func rawValueRoundTrips() {
        let session = ExamSession(year: 2027, month: .may)
        #expect(session.rawValue == "2027-05")
        #expect(ExamSession(rawValue: "2027-05") == session)

        let november = ExamSession(year: 2026, month: .november)
        #expect(november.rawValue == "2026-11")
        #expect(ExamSession(rawValue: "2026-11") == november)
    }

    @Test("the stored form matches what the database will accept")
    func rawValueMatchesServerPattern() {
        // The column is checked against ^[0-9]{4}-(05|11)$. A four-digit year
        // and a zero-padded month are not cosmetic; an unpadded "2027-5" is
        // rejected by Postgres and would fail only at the network boundary.
        for session in [ExamSession(year: 2027, month: .may),
                        ExamSession(year: 2028, month: .november)] {
            #expect(session.rawValue.count == 7)
            #expect(session.rawValue.wholeMatch(of: /[0-9]{4}-(05|11)/) != nil)
        }
    }

    @Test("nonsense never becomes a session")
    func rejectsMalformedInput() {
        // Every one of these would otherwise reach a generated prompt.
        for bad in ["", "2027", "2027-5", "2027-06", "2027-13", "27-05",
                    "2027-05-01", "abcd-05", "2027-0５"] {
            #expect(ExamSession(rawValue: bad) == nil, "accepted \(bad)")
        }
    }

    // MARK: - Deriving the year

    @Test("a student two years out is DP1, one year out is DP2")
    func derivesYearWithinProgramme() {
        let may2027 = ExamSession(year: 2027, month: .may)

        // Eighteen months before the exam: first year.
        #expect(may2027.diplomaYear(on: date(2025, 11, 1), calendar: calendar) == 1)
        // Six months before: second year.
        #expect(may2027.diplomaYear(on: date(2026, 11, 1), calendar: calendar) == 2)
    }

    @Test("the DP1 to DP2 rollover happens on its own, with nothing to update")
    func rolloverNeedsNoWrite() {
        // This is the entire reason the session is stored rather than the year.
        // One stored value; the answer changes correctly as time passes.
        let session = ExamSession(year: 2027, month: .may)

        #expect(session.diplomaYear(on: date(2026, 4, 30), calendar: calendar) == 1)
        #expect(session.diplomaYear(on: date(2026, 5, 2), calendar: calendar) == 2)
    }

    @Test("a finished session yields no year rather than inventing DP3")
    func pastSessionIsNil() {
        let may2026 = ExamSession(year: 2026, month: .may)
        #expect(may2026.diplomaYear(on: date(2026, 9, 1), calendar: calendar) == nil)
        #expect(may2026.diplomaYear(on: date(2030, 1, 1), calendar: calendar) == nil)
    }

    @Test("a session more than two years out yields no year")
    func beforeProgrammeIsNil() {
        let may2030 = ExamSession(year: 2030, month: .may)
        #expect(may2030.diplomaYear(on: date(2026, 9, 1), calendar: calendar) == nil)
    }

    @Test("November sessions derive their year the same way")
    func novemberSessionsWork() {
        let november2027 = ExamSession(year: 2027, month: .november)
        #expect(november2027.diplomaYear(on: date(2026, 5, 1), calendar: calendar) == 1)
        #expect(november2027.diplomaYear(on: date(2027, 5, 1), calendar: calendar) == 2)
        #expect(november2027.diplomaYear(on: date(2027, 12, 1), calendar: calendar) == nil)
    }

    // MARK: - Asking the question a student can answer

    @Test("onboarding's DP1 or DP2 converts to a session, and back again")
    func diplomaYearConvertsToSessionAndBack() {
        // A student saying "DP2" in September 2026 sits May 2027; saying "DP1"
        // sits May 2028. Converting back must return what they said.
        let now = date(2026, 9, 1)

        let dp2 = ExamSession.forDiplomaYear(2, on: now, calendar: calendar)
        #expect(dp2 == ExamSession(year: 2027, month: .may))
        #expect(dp2?.diplomaYear(on: now, calendar: calendar) == 2)

        let dp1 = ExamSession.forDiplomaYear(1, on: now, calendar: calendar)
        #expect(dp1 == ExamSession(year: 2028, month: .may))
        #expect(dp1?.diplomaYear(on: now, calendar: calendar) == 1)
    }

    @Test("a student onboarding before May sits that same May")
    func beforeMayUsesThisYear() {
        // In February 2027, a DP2 student has exams in three months, not
        // fifteen. Rolling forward a year here would tell them they had a year
        // longer than they do, on the screen where that matters most.
        let dp2 = ExamSession.forDiplomaYear(2, on: date(2027, 2, 1), calendar: calendar)
        #expect(dp2 == ExamSession(year: 2027, month: .may))
    }

    @Test("only 1 and 2 are Diploma years")
    func rejectsInvalidDiplomaYear() {
        for bad in [-1, 0, 3, 13] {
            #expect(ExamSession.forDiplomaYear(bad, on: date(2026, 9, 1),
                                               calendar: calendar) == nil)
        }
    }

    // MARK: - Level

    @Test("level is a closed set, not a string")
    func levelIsConstrained() {
        #expect(CourseLevel(rawValue: "HL") == .hl)
        #expect(CourseLevel(rawValue: "SL") == .sl)
        // Anything else must not reach a prompt.
        for bad in ["hl", "sl", "Higher", "", "HL ", "SL;DROP"] {
            #expect(CourseLevel(rawValue: bad) == nil, "accepted \(bad)")
        }
    }

    @Test("level raw values are exactly what the column allows")
    func levelMatchesServerConstraint() {
        #expect(Set(CourseLevel.allCases.map(\.rawValue)) == ["HL", "SL"])
    }
}
