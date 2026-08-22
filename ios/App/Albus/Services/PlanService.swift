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
        let steps: [Step]

        private enum CodingKeys: String, CodingKey {
            case assignmentID = "assignment_id"
            case model
            case rubricGrounded = "rubric_grounded"
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
        let assessment_type_id: String?
    }

    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    func breakdown(title: String, taskType: String, deadline: Date,
                   estimatedMinutes: Int, assessmentTypeID: UUID? = nil) async throws -> Result {
        let body = Request(
            title: title,
            task_type: taskType,
            deadline: ISO8601DateFormatter().string(from: deadline),
            estimated_minutes: estimatedMinutes,
            assessment_type_id: assessmentTypeID?.uuidString
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
