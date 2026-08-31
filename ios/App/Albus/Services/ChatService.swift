import Foundation
import Supabase
import AlbusCore

/// Ask Albus. A question about one assignment, answered against its own plan.
///
/// The assignment is identified by id only; the server loads it through the
/// caller's own token, so RLS decides what can enter the context window. This
/// client never sends plan text — a forged id simply finds nothing.
struct ChatService {

    struct Turn: Codable, Equatable, Sendable, Identifiable {
        enum Role: String, Codable, Sendable { case user, assistant }
        var id = UUID()
        let role: Role
        let content: String

        private enum CodingKeys: String, CodingKey { case role, content }
    }

    struct Reply: Decodable, Sendable {
        let reply: String
        let grounded: Bool
    }

    /// Its own reasons, no longer `PlanService.Failure`.
    ///
    /// The two endpoints used to share a failure type on the argument that they
    /// failed for the same reasons. Under three plans they do not: planning is
    /// bounded by how many tasks a student holds open, and Ask Albus by a
    /// monthly message allowance that Free does not have at all. One shared
    /// type would have to say something vague enough to be true of both, and
    /// "you have reached a limit" is not worth showing anybody.
    enum Failure: LocalizedError, Equatable {
        /// This plan has no Ask Albus. The answer is a price list.
        case notOnPlan
        /// The plan includes it and this month's messages are gone. Carries
        /// when the next one arrives, which is the only actionable part.
        case allowanceUsed(resetsAt: Date?)
        case rateLimited
        case fairUseReached
        case offline
        case unavailable
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .notOnPlan:
                "Ask Albus is part of Pro."
            case .allowanceUsed(let resetsAt):
                if let resetsAt, resetsAt > .now {
                    "That's this month's messages used. The next one is back "
                    + "\(resetsAt.formatted(date: .abbreviated, time: .omitted))."
                } else {
                    "That's this month's messages used."
                }
            case .rateLimited:
                "That's a lot of questions at once. Try again shortly."
            case .fairUseReached:
                "This account has reached its monthly AI safety limit. "
                + "Capacity returns gradually over 30 days."
            case .offline:
                "No connection — Albus needs one to answer."
            case .unavailable:
                "Albus can't answer right now."
            case .rejected(let why):
                why
            }
        }

        /// Whether a different plan is the way out. Drives whether the screen
        /// offers a price list; nothing else decides it.
        var isAnswerableByUpgrading: Bool {
            switch self {
            case .notOnPlan, .allowanceUsed: true
            default: false
            }
        }
    }

    /// Matches `MAX_HISTORY_TURNS` in `_shared/chat_prompt.ts`. The server
    /// clamps regardless; trimming here just avoids paying to send what will
    /// be discarded.
    static let maxHistoryTurns = 8
    /// Matches `MAX_MESSAGE_CHARS`.
    static let maxMessageChars = 2000

    private struct Request: Encodable {
        let message: String
        let assignment_id: String?
        let history: [Turn]
        /// 1-based step the student is looking at, when they picked one. The
        /// server still sends the whole plan — this only says which part of it
        /// the question is about.
        let step: Int?
    }

    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    func send(_ message: String, about assignmentID: UUID, step: Int? = nil,
              history: [Turn]) async throws -> Reply {
        let trimmed = String(message.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxMessageChars))
        guard !trimmed.isEmpty else { throw Failure.rejected("Type a question first.") }
        guard let client else { throw Failure.unavailable }

        let body = Request(
            message: trimmed,
            assignment_id: assignmentID.uuidString.lowercased(),
            history: Array(history.suffix(Self.maxHistoryTurns)),
            step: step
        )

        do {
            return try await client.functions.invoke(
                "chat", options: .init(headers: DeviceSignal.headers(), body: body))
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
        case "PLAN_UPGRADE_REQUIRED":                 return .notOnPlan
        case "ALLOWANCE_MONTHLY":                     return .allowanceUsed(resetsAt: nil)
        case "RATE_LIMIT_HOURLY", "RATE_LIMIT_DAILY": return .rateLimited
        case "FAIR_USE_REACHED":                      return .fairUseReached
        case "VERIFICATION_REQUIRED", "ABUSE_SUSPECTED":
            // Both carry a message written for a student to read, and neither
            // is a thing the app can fix by offering a plan.
            return .rejected(body?.message ?? "Albus can't answer right now.")
        case "GLOBAL_CAPACITY_REACHED":               return .unavailable
        case "MESSAGE_TOO_LONG":                      return .rejected("That message is too long.")
        default: break
        }

        switch code {
        // An unrecognised 402 is *some* payment-shaped refusal, and the two it
        // could be want opposite sentences. Rather than guess — and eventually
        // tell a subscriber to buy what they already have — hand back what the
        // server said. It is the one party that knows which it was.
        case 402, 403: return .rejected(body?.message ?? "Albus couldn't answer that.")
        case 429:      return .rateLimited
        case 413:      return .rejected("That message is too long.")
        case 422:      return .rejected(body?.message ?? "Albus couldn't answer that.")
        default:       return .unavailable
        }
    }
}
