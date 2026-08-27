import Foundation
import Supabase

/// Sends finished work to be marked against the student's own rubric.
///
/// Transport only. The paywall, the rate limit and the size cap are all
/// server-side — this type cannot enforce any of them and does not pretend to.
/// What it *does* own is telling the student the truth about what came back,
/// which is why `Failure` is a closed set of cases rather than a string: a new
/// server error must never render to a student as raw text.
struct GradingService {

    struct Criterion: Decodable, Sendable {
        let code: String?
        let name: String
        let marks: Int?
        let outOf: Int?
        let comment: String
        let quote: String?
        let whereFound: String?

        private enum CodingKeys: String, CodingKey {
            case code, name, marks, comment, quote
            case outOf = "out_of"
            case whereFound = "where"
        }
    }

    struct Improvement: Decodable, Sendable {
        let change: String
        let why: String
    }

    struct Result: Decodable, Sendable {
        let id: UUID
        let overallMarks: Int?
        let totalMarks: Int?
        /// The grade, in the scale the student said their course uses.
        ///
        /// Distinct from `overallMarks` on purpose: a four-strand MYP rubric
        /// totals 32, and 0/32 is arithmetic rather than a grade. Guaranteed
        /// nil for a blind reading — the server strips it after the model has
        /// spoken, so a label cannot arrive on a reading that is not a grade.
        let gradeLabel: String?
        let gradeNote: String?
        /// What was marked, echoed back so history rows have a name.
        let title: String?
        let criteria: [Criterion]
        let feedback: String
        let improvements: [Improvement]
        let model: String
        /// What the marks were based on, decided server-side.
        ///
        /// Never inferred from whether marks came back: a curriculum rubric
        /// carrying no marks and a blind reading both arrive as nils, and only
        /// one of them may be shown as a grade.
        let basis: GradingBasis
        /// The rubric's name, for "marking against …". Nil when blind.
        let rubricName: String?
        /// True when the server returned an identical earlier grading instead
        /// of paying to produce the same one again.
        let reused: Bool

        private enum CodingKeys: String, CodingKey {
            case id, criteria, feedback, improvements, model, basis, reused, title
            case overallMarks = "overall_marks"
            case totalMarks = "total_marks"
            case gradeLabel = "grade_label"
            case gradeNote = "grade_note"
            case rubricName = "rubric_name"
        }
    }

    /// How many gradings are left, and which limit is the one that will
    /// actually stop the student.
    ///
    /// Advisory: the real gate runs in Postgres in the same transaction that
    /// reserves the slot. This exists so the number can be shown without
    /// spending a grading to discover it.
    ///
    /// **It reports three windows because reporting one was a lie.** The meter
    /// drew five dots and said "3 left this week" while the thing that actually
    /// stopped a free student was a daily cap of two — so the screen showed
    /// three remaining directly above "that's this week's markings used". Both
    /// numbers were true. Together they were nonsense.
    struct Allowance: Decodable, Sendable {
        let usedHour: Int
        let limitHour: Int
        let usedDay: Int
        let limitDay: Int
        let usedWeek: Int
        let limitWeek: Int
        let isPlus: Bool

        /// When the oldest call in each window falls out of it. Strings on the
        /// wire, parsed here: Postgres sends microsecond precision and a `+00`
        /// offset, and a decoder that only understands one ISO variant turns a
        /// working meter into a decode failure.
        let hourResetsAt: Date?
        let dayResetsAt: Date?
        let weekResetsAt: Date?

        enum Window: Sendable, Equatable {
            case hour, day, week

            /// How the window reads in a sentence about what is left.
            var phrase: String {
                switch self {
                case .hour: "this hour"
                case .day:  "today"
                case .week: "this week"
                }
            }
        }

        /// The window closest to stopping the student, and the only one worth
        /// putting on screen.
        ///
        /// Ties break toward the *longer* window, which is the whole point: a
        /// free student who has used two is at zero on both the hour and the
        /// day, and naming the hour would promise a grading back in an hour
        /// that the daily cap will refuse to hand over.
        struct Binding: Sendable {
            let window: Window
            let remaining: Int
            let limit: Int
            let resetsAt: Date?
        }

        var binding: Binding {
            // A limit of zero means "no ceiling", not "none left" — that is how
            // Plus is expressed, and reading it the other way would tell a
            // paying student they had run out.
            let candidates: [Binding] = [
                Binding(window: .hour, remaining: max(0, limitHour - usedHour),
                        limit: limitHour, resetsAt: hourResetsAt),
                Binding(window: .day, remaining: max(0, limitDay - usedDay),
                        limit: limitDay, resetsAt: dayResetsAt),
                Binding(window: .week, remaining: max(0, limitWeek - usedWeek),
                        limit: limitWeek, resetsAt: weekResetsAt),
            ].filter { $0.limit > 0 }

            guard var tightest = candidates.first else {
                return Binding(window: .week, remaining: .max, limit: 0, resetsAt: nil)
            }
            for candidate in candidates.dropFirst() where candidate.remaining <= tightest.remaining {
                tightest = candidate
            }
            return tightest
        }

        /// Nil when nothing caps this student at all.
        var remaining: Int? { binding.limit > 0 ? binding.remaining : nil }
        var hasAny: Bool { remaining.map { $0 > 0 } ?? true }

        private enum CodingKeys: String, CodingKey {
            case usedHour = "used_hour"
            case limitHour = "limit_hour"
            case usedDay = "used_day"
            case limitDay = "limit_day"
            case usedWeek = "used_week"
            case limitWeek = "limit_week"
            case hourResetsAt = "hour_resets_at"
            case dayResetsAt = "day_resets_at"
            case weekResetsAt = "week_resets_at"
            case isPlus = "is_plus"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedHour = try c.decode(Int.self, forKey: .usedHour)
            limitHour = try c.decode(Int.self, forKey: .limitHour)
            usedDay = try c.decode(Int.self, forKey: .usedDay)
            limitDay = try c.decode(Int.self, forKey: .limitDay)
            usedWeek = try c.decode(Int.self, forKey: .usedWeek)
            limitWeek = try c.decode(Int.self, forKey: .limitWeek)
            isPlus = try c.decode(Bool.self, forKey: .isPlus)
            hourResetsAt = Self.timestamp(try c.decodeIfPresent(String.self, forKey: .hourResetsAt))
            dayResetsAt = Self.timestamp(try c.decodeIfPresent(String.self, forKey: .dayResetsAt))
            weekResetsAt = Self.timestamp(try c.decodeIfPresent(String.self, forKey: .weekResetsAt))
        }

        /// Used only by the previews and tests, which have no wire to decode.
        init(usedHour: Int, limitHour: Int, usedDay: Int, limitDay: Int,
             usedWeek: Int, limitWeek: Int, isPlus: Bool = false,
             hourResetsAt: Date? = nil, dayResetsAt: Date? = nil, weekResetsAt: Date? = nil) {
            self.usedHour = usedHour; self.limitHour = limitHour
            self.usedDay = usedDay; self.limitDay = limitDay
            self.usedWeek = usedWeek; self.limitWeek = limitWeek
            self.isPlus = isPlus
            self.hourResetsAt = hourResetsAt
            self.dayResetsAt = dayResetsAt
            self.weekResetsAt = weekResetsAt
        }

        /// Postgres timestamps, both variants.
        ///
        /// `.withFractionalSeconds` and plain ISO8601 are separate formatter
        /// configurations and each rejects the other's output, so a single
        /// formatter silently loses every reset time the moment a row happens
        /// to land on a whole second.
        static func timestamp(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            // Postgres writes "+00"; ISO8601 wants "+00:00" or "Z".
            let normalised = raw.replacingOccurrences(
                of: #"([+-]\d{2})$"#, with: "$1:00", options: .regularExpression)
            for options in [[ISO8601DateFormatter.Options.withInternetDateTime,
                             .withFractionalSeconds],
                            [ISO8601DateFormatter.Options.withInternetDateTime]] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = ISO8601DateFormatter.Options(options)
                if let date = formatter.date(from: normalised) { return date }
            }
            return nil
        }
    }

    enum Failure: LocalizedError, Equatable {
        /// The allowance for one window is gone — and *which* window, because
        /// getting that wrong is what made the meter unreadable.
        ///
        /// There used to be two cases here: `needsPlus`, which said "that's this
        /// week's markings used", and `rateLimited`, which said "that's a lot of
        /// marking at once". A free student who marked two drafts in an evening
        /// hit the *daily* cap and was told their week was gone — while the
        /// meter beside it still showed three left. One case carrying the window
        /// makes that shape of bug unstateable.
        case usedUp(Allowance.Window)
        case tooLong(Int)
        /// Accepted, marked, and the answer ran past what the model could
        /// write in one go. Not the same as `tooLong`, which is refused before
        /// anything is spent.
        case tooLongToMark
        case tooShort
        case noRubric
        case offline
        case unavailable
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .usedUp(let window):
                switch window {
                case .hour: "That's this hour's markings used. Albus Plus raises the limit."
                case .day:  "That's today's markings used. Albus Plus raises the limit."
                case .week: "That's this week's markings used. Albus Plus raises the limit."
                }
            case .tooLong(let max):
                "That's longer than Albus can mark in one go (about \(max / 6) words)."
            case .tooLongToMark:
                "There was too much to say about that in one go. Try marking a "
                + "section of it, or a rubric with fewer criteria."
            case .tooShort:
                "There isn't enough here to mark yet."
            case .noRubric:
                "Pick a rubric to mark this against."
            case .offline:
                "No connection — marking needs one."
            case .unavailable:
                // Never "nothing was charged" — the client cannot know that. A
                // grading is reserved before the model runs, so a failure here
                // may or may not have cost one, and claiming otherwise was a
                // lie a student could check. The server hands the slot back on
                // failure and returns an identical result for free on a retry,
                // which is what makes this true rather than reassuring.
                "Albus couldn't finish marking that. Try again — you won't be charged twice."
            case .rejected(let why):
                why
            }
        }
    }

    /// Mirrors MAX_WORK_CHARS in the edge function. Used for a local warning
    /// only — the server rejects rather than truncates, so this being out of
    /// step costs a worse message, never a wrong grade.
    static let maxWorkCharacters = 40_000
    static let minWorkCharacters = 200

    private struct Request: Encodable {
        let assignment_id: String?
        /// Optional now, and only an override — the server works the rubric out
        /// from the assignment when this is absent.
        let rubric_id: String?
        let work: String
        /// How the student asked for the result to be shown, in their words.
        let presentation: String?
        /// What the student calls this piece — a filename, "Photo of your
        /// work", the assignment's own title. Only ever labels their own
        /// history row; the server fences it before it reaches the model.
        let title: String?
    }

    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// How many gradings are left. Never throws upward — a meter that cannot be
    /// drawn is not a reason to block marking.
    func allowance() async -> Allowance? {
        guard let client else { return nil }
        let rows: [Allowance]? = try? await client.rpc("grading_allowance").execute().value
        return rows?.first
    }

    /// Marks a piece of work.
    ///
    /// Both ids are optional and the pair decides what happens. An assignment
    /// lets the server find the right mark scheme by itself; an explicit rubric
    /// overrides that; neither means a blind reading, which is a supported
    /// outcome rather than a failure.
    func grade(work: String, rubricID: UUID?, assignmentID: UUID?,
               presentation: String?, title: String? = nil) async throws -> Result {
        guard let client else { throw Failure.unavailable }

        let trimmed = work.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked here as well as on the server, so an obviously-too-short
        // submission does not cost a round trip to be told so.
        guard trimmed.count >= Self.minWorkCharacters else { throw Failure.tooShort }
        guard trimmed.count <= Self.maxWorkCharacters else {
            throw Failure.tooLong(Self.maxWorkCharacters)
        }

        let body = Request(assignment_id: assignmentID?.uuidString,
                           rubric_id: rubricID?.uuidString,
                           work: trimmed,
                           presentation: presentation?
                               .trimmingCharacters(in: .whitespacesAndNewlines)
                               .nilIfEmpty,
                           title: title?
                               .trimmingCharacters(in: .whitespacesAndNewlines)
                               .nilIfEmpty)

        do {
            // Marking a full essay on Opus legitimately runs past thirty
            // seconds, which is long enough for the default request timeout to
            // give up on a request the server is still happily working on. The
            // student then sees a failure for work that was in fact marked, and
            // has spent a grading to see it.
            return try await client.functions.invoke("grade", options: .init(body: body))
        } catch let error as FunctionsError {
            throw Self.translate(error)
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                ? Failure.offline
                : Failure.unavailable
        }
    }

    private static func translate(_ error: FunctionsError) -> Failure {
        guard case .httpError(let code, let data) = error else { return .unavailable }

        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch body?.error {
        // `PLUS_REQUIRED` and `RUBRIC_REQUIRED` were removed rather than kept
        // "just in case": no database function can raise the first any more
        // (checked against pg_proc, not assumed), and the endpoint no longer
        // rejects a missing rubric — it grades blind instead. A branch that
        // cannot be reached is a branch nobody will maintain correctly.
        case "RATE_LIMIT_WEEKLY":                       return .usedUp(.week)
        case "RATE_LIMIT_DAILY":                        return .usedUp(.day)
        case "RATE_LIMIT_HOURLY":                       return .usedUp(.hour)
        case "WORK_TOO_LONG":                           return .tooLong(maxWorkCharacters)
        case "WORK_TOO_SHORT":                          return .tooShort
        case "RUBRIC_NOT_FOUND":                        return .noRubric
        case "GLOBAL_CAPACITY_REACHED":                 return .unavailable
        // Marking ran past the output cap. Distinct from an ordinary failure
        // because retrying identical work will truncate identically — the
        // student needs to know to send less, not to try again.
        case "RESPONSE_TRUNCATED":                      return .tooLongToMark
        default: break
        }

        switch code {
        // Falling back to the day rather than the week: it is the tighter of
        // the two for every tier, so a guess here understates what is left
        // rather than telling a student their week is gone when it is not.
        case 402:      return .usedUp(.week)
        case 429:      return .usedUp(.day)
        case 413:      return .tooLong(maxWorkCharacters)
        case 404, 422: return .rejected(body?.message ?? "Albus couldn't mark that.")
        default:       return .unavailable
        }
    }
}
