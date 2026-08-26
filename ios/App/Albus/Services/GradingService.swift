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

        private enum CodingKeys: String, CodingKey {
            case code, name, marks, comment
            case outOf = "out_of"
        }
    }

    struct Result: Decodable, Sendable {
        let id: UUID
        let overallMarks: Int?
        let totalMarks: Int?
        let criteria: [Criterion]
        let feedback: String
        let model: String

        private enum CodingKeys: String, CodingKey {
            case id, criteria, feedback, model
            case overallMarks = "overall_marks"
            case totalMarks = "total_marks"
        }
    }

    enum Failure: LocalizedError, Equatable {
        /// The free week's markings are used up. Not an error the student did
        /// anything wrong to cause, so the UI shows a paywall, never an alert.
        ///
        /// This used to mean "grading is Plus-only", which gated the feature so
        /// completely that it was never once reached. It now means the far
        /// narrower thing it should always have meant: you have had your free
        /// ones this week.
        case needsPlus
        case rateLimited
        case tooLong(Int)
        case tooShort
        case noRubric
        case offline
        case unavailable
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .needsPlus:
                "That's this week's markings used. Albus Plus raises the limit."
            case .rateLimited:
                "That's a lot of marking at once. Try again shortly."
            case .tooLong(let max):
                "That's longer than Albus can mark in one go (about \(max / 6) words)."
            case .tooShort:
                "There isn't enough here to mark yet."
            case .noRubric:
                "Pick a rubric to mark this against."
            case .offline:
                "No connection — marking needs one."
            case .unavailable:
                "Albus can't mark this right now. Nothing was charged."
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
        let rubric_id: String
        let work: String
    }

    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    func grade(work: String, rubricID: UUID, assignmentID: UUID?) async throws -> Result {
        guard let client else { throw Failure.unavailable }

        let trimmed = work.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked here as well as on the server, so an obviously-too-short
        // submission does not cost a round trip to be told so.
        guard trimmed.count >= Self.minWorkCharacters else { throw Failure.tooShort }
        guard trimmed.count <= Self.maxWorkCharacters else {
            throw Failure.tooLong(Self.maxWorkCharacters)
        }

        let body = Request(assignment_id: assignmentID?.uuidString,
                           rubric_id: rubricID.uuidString,
                           work: trimmed)

        do {
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
        case "RATE_LIMIT_WEEKLY":                       return .needsPlus
        case "RATE_LIMIT_HOURLY", "RATE_LIMIT_DAILY":   return .rateLimited
        case "WORK_TOO_LONG":                           return .tooLong(maxWorkCharacters)
        case "WORK_TOO_SHORT":                          return .tooShort
        case "RUBRIC_NOT_FOUND":                        return .noRubric
        case "GLOBAL_CAPACITY_REACHED":                 return .unavailable
        default: break
        }

        switch code {
        case 402:      return .needsPlus
        case 429:      return .rateLimited
        case 413:      return .tooLong(maxWorkCharacters)
        case 404, 422: return .rejected(body?.message ?? "Albus couldn't mark that.")
        default:       return .unavailable
        }
    }
}
