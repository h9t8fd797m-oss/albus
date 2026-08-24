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

    /// Reuses `PlanService.Failure` rather than defining a parallel set: the
    /// two endpoints fail for the same reasons and a student should not get two
    /// different sentences for one quota.
    typealias Failure = PlanService.Failure

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

    func send(_ message: String, about assignmentID: UUID?, step: Int? = nil,
              history: [Turn]) async throws -> Reply {
        let trimmed = String(message.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxMessageChars))
        guard !trimmed.isEmpty else { throw Failure.rejected("Type a question first.") }
        guard let client else { throw Failure.unavailable }

        let body = Request(
            message: trimmed,
            assignment_id: assignmentID?.uuidString.lowercased(),
            history: Array(history.suffix(Self.maxHistoryTurns)),
            step: step
        )

        do {
            return try await client.functions.invoke("chat", options: .init(body: body))
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
        case "RATE_LIMIT_HOURLY", "RATE_LIMIT_DAILY": return .rateLimited
        case "GLOBAL_CAPACITY_REACHED":               return .unavailable
        case "MESSAGE_TOO_LONG":                      return .rejected("That message is too long.")
        default: break
        }

        switch code {
        case 402:      return .quotaReached
        case 429:      return .rateLimited
        case 413:      return .rejected("That message is too long.")
        case 422:      return .rejected(body?.message ?? "Albus couldn't answer that.")
        default:       return .unavailable
        }
    }
}
