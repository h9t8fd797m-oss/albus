import Foundation
import Supabase
import AlbusCore

/// Asks the backend to turn an assignment into startable steps.
///
/// The server owns generation because it holds the Anthropic key and enforces
/// the quota; both would be trivially bypassed on device. This type is only
/// the transport — it does not decide what a plan should look like.
struct PlanService {

    struct Step: Decodable, Sendable {
        let title: String
        let guidance: String
        let estimatedMinutes: Int
        let criterionCode: String?

        private enum CodingKeys: String, CodingKey {
            case title, guidance
            case estimatedMinutes = "estimated_minutes"
            case criterionCode = "rubric_criterion_code"
        }
    }

    struct Result: Decodable, Sendable {
        let assignmentID: UUID
        let model: String
        let rubricGrounded: Bool
        /// "personal", "curriculum", or nil when the plan was generic. Lets the
        /// UI tell the student *which* rubric shaped their plan.
        let rubricSource: String?
        let steps: [Step]

        private enum CodingKeys: String, CodingKey {
            case assignmentID = "assignment_id"
            case model
            case rubricGrounded = "rubric_grounded"
            case rubricSource = "rubric_source"
            case steps
        }
    }

    /// Maps the server's error codes onto something a screen can act on.
    /// Kept as cases rather than strings so a new server error cannot be
    /// silently rendered as raw text to a student.
    enum Failure: LocalizedError, Equatable {
        case quotaReached
        case rateLimited
        case offline
        case unavailable
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .quotaReached:
                "Free plans cover three assignments at a time. Finish one to start another."
            case .rateLimited:
                "That's a lot of planning at once. Try again shortly."
            case .offline:
                "No connection — Albus will plan this when you're back online."
            case .unavailable:
                "Albus can't plan right now. Your assignment is saved."
            case .rejected(let why):
                why
            }
        }
    }

    private struct Request: Encodable {
        let title: String
        let task_type: String
        let deadline: String
        let estimated_minutes: Int
        /// Which curriculum subject and which of its components, by code. The
        /// server resolves the pair against its own copy of the specification;
        /// nothing about how the work is assessed is taken from the client.
        let course_template_code: String?
        let assessment_code: String?
        let course_id: String?
        /// What the student typed about the assignment. Reaches the model
        /// fenced as data; the server caps it at 2000 characters.
        let notes: String?
        /// The student's own rubric, by id. The rubric itself is never sent —
        /// the server loads it through the caller's own RLS context, so a
        /// forged id resolves to nothing rather than to someone else's rubric.
        let rubric_id: String?
        let priority: String
    }

    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    func breakdown(title: String, taskType: String, deadline: Date,
                   estimatedMinutes: Int,
                   courseTemplateCode: String? = nil, assessmentCode: String? = nil,
                   courseID: UUID? = nil, notes: String? = nil,
                   rubricID: UUID? = nil,
                   priority: AssignmentPriority = .normal) async throws -> Result {
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)

        let body = Request(
            title: title,
            task_type: taskType,
            deadline: ISO8601DateFormatter().string(from: deadline),
            estimated_minutes: estimatedMinutes,
            course_template_code: courseTemplateCode,
            assessment_code: assessmentCode,
            course_id: courseID?.uuidString,
            notes: (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes,
            rubric_id: rubricID?.uuidString,
            priority: priority.rawValue
        )

        guard let client else { throw Failure.unavailable }

        do {
            return try await client.functions.invoke("breakdown", options: .init(body: body))
        } catch let error as FunctionsError {
            throw Self.translate(error)
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                ? Failure.offline
                : Failure.unavailable
        }
    }

    /// The server returns a machine-readable code; surface the ones a student
    /// can act on and collapse the rest into "unavailable". Leaking internal
    /// error text to a UI is how implementation details end up on screen.
    private static func translate(_ error: FunctionsError) -> Failure {
        guard case .httpError(let code, let data) = error else { return .unavailable }

        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch body?.error {
        case "FREE_PLAN_LIMIT_REACHED":                 return .quotaReached
        case "RATE_LIMIT_HOURLY", "RATE_LIMIT_DAILY":   return .rateLimited
        case "GLOBAL_CAPACITY_REACHED":                 return .unavailable
        default: break
        }

        switch code {
        case 402:        return .quotaReached
        case 429:        return .rateLimited
        case 422, 413:   return .rejected(body?.message ?? "Albus couldn't plan that.")
        default:         return .unavailable
        }
    }
}
