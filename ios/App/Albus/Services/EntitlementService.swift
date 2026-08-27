import Foundation
import Supabase
import AlbusCore

/// What this student's plan includes, and how much of it they have used.
///
/// **Read-only, and asked of the server.** The app never decides its own tier
/// and never caches it as a durable fact: `entitlements` is server-written,
/// clients hold only a SELECT grant, and every limit that matters is enforced
/// again inside the database — in the same transaction as the write, under a
/// per-user lock. This exists to show the right screen, not to gate anything. A
/// tampered value here buys a nicer paywall and nothing else.
@Observable
@MainActor
final class EntitlementService {

    /// Three tiers, ordered. **Never compare tier names to decide access** —
    /// `tier == .plus` is false for a Pro subscriber, which is the same shape
    /// of bug as the NULL comparison migration 0009 had to fix, one level up.
    /// Ask the plan what it includes instead.
    enum Tier: String, Sendable, Comparable, CaseIterable {
        case free, plus, pro

        private var rank: Int {
            switch self {
            case .free: 0
            case .plus: 1
            case .pro:  2
            }
        }
        static func < (a: Tier, b: Tier) -> Bool { a.rank < b.rank }
    }

    enum ToolsAccess: String, Sendable, Decodable {
        case basic, expanded, all
    }

    /// One metered feature: how much the plan allows, how much is gone, and
    /// when the next one arrives.
    ///
    /// **`nil` is unlimited. `0` is not included.** Those are different
    /// products, different screens and different sentences — "upgrade to get
    /// this" is not "you'll have another on Tuesday" — and the app used to
    /// carry the opposite convention, where `0` meant "no ceiling" because that
    /// was how Plus was expressed. A Free tier that genuinely gets zero
    /// gradings would have read as unlimited marking. Everything below spells
    /// the distinction out rather than leaving it to a comparison.
    struct Allowance: Sendable, Equatable {
        let limit: Int?
        let used: Int
        let resetsAt: Date?

        init(limit: Int?, used: Int = 0, resetsAt: Date? = nil) {
            self.limit = limit
            self.used = used
            self.resetsAt = resetsAt
        }

        /// False only when the plan does not cover this feature at all.
        var isIncluded: Bool { limit != 0 }
        var isUnlimited: Bool { limit == nil }

        /// Nil when nothing caps this. Never negative — a limit that drops
        /// below what has already been spent (a downgrade mid-period) would
        /// otherwise render as "-3 left".
        var remaining: Int? {
            guard let limit else { return nil }
            return max(0, limit - used)
        }

        /// Whether the student can do this right now.
        var hasAny: Bool {
            guard isIncluded else { return false }
            guard let remaining else { return true }
            return remaining > 0
        }

        /// What the meter says. Deliberately three different sentences.
        var summary: String {
            guard isIncluded else { return "Not on this plan" }
            guard let remaining else { return "Unlimited" }
            return "\(remaining) of \(limit ?? 0) left"
        }
    }

    /// The plan, its limits and the caller's usage — one row, one round trip.
    ///
    /// Replaces `grading_allowance()`, which reported only the grader and
    /// carried the reversed sentinel. That function was dropped rather than
    /// kept working: a client still holding the old reading would show a free
    /// student unlimited marking, and a missing function is a loud failure
    /// where a reversed sentinel is a silent one.
    struct Plan: Sendable, Equatable {
        let tier: Tier
        let displayName: String
        let priceCents: Int
        let currency: String
        let expiresAt: Date?

        let tasks: Allowance
        let chat: Allowance
        let grader: Allowance
        let rubrics: Allowance

        let toolsAccess: ToolsAccess
        let curriculumIntelligence: Bool
        let advancedModels: Bool

        /// The price as a student reads it. Zero is "Free", not "€0.00".
        var priceLabel: String {
            guard priceCents > 0 else { return "Free" }
            let symbol = currency == "EUR" ? "€" : currency == "GBP" ? "£" : "$"
            return String(format: "\(symbol)%.2f", Double(priceCents) / 100)
        }

        /// Everything Albus can do that this plan does not include. Drives the
        /// "what you'd get" list without hardcoding a comparison table.
        var isPaid: Bool { tier > .free }

        static let freeFallback = Plan(
            tier: .free, displayName: "Free", priceCents: 0, currency: "EUR", expiresAt: nil,
            tasks: Allowance(limit: 5), chat: Allowance(limit: 0),
            grader: Allowance(limit: 0), rubrics: Allowance(limit: 3),
            toolsAccess: .basic, curriculumIntelligence: false, advancedModels: false)
    }

    private(set) var plan: Plan = .freeFallback
    private(set) var lastCheckedAt: Date?
    private(set) var isLoading = false

    var tier: Tier { plan.tier }

    /// True while a paid period is genuinely current, whatever the row says.
    /// An expiry in the past is free — the same comparison the database makes,
    /// so the two cannot disagree about what a stale row means.
    var isPaid: Bool {
        guard plan.tier > .free else { return false }
        guard let expiresAt = plan.expiresAt else { return true }
        return expiresAt > .now
    }

    private let reader: PlanReader

    init(reader: PlanReader = PlanReader()) {
        self.reader = reader
    }

    /// Refreshes from the server.
    ///
    /// Failure leaves the previous value alone rather than downgrading: a
    /// dropped connection must not make a paying student look free, and the
    /// server would refuse anything they were not entitled to anyway.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let fetched = try await reader.fetch() {
                plan = fetched
                lastCheckedAt = .now
            }
        } catch {
            print("[Albus] plan refresh failed: \(error.localizedDescription)")
        }
    }
}

/// The network half, deliberately outside the MainActor class.
///
/// `PostgrestResponse` is not Sendable, so awaiting `.execute()` from an
/// actor-isolated method means returning a non-Sendable value across an
/// isolation boundary — which Xcode 16.4 rejects and Xcode 26 allows. Keeping
/// the request in a plain nonisolated type means only the decoded, Sendable
/// value ever crosses. Same shape as PlanService, for the same reason.
struct PlanReader: Sendable {

    /// The wire shape of `my_plan()`. Flat, because a Postgres function
    /// returning a table returns one flat row.
    private struct Row: Decodable, Sendable {
        let tier: String
        let displayName: String
        let priceCents: Int
        let currency: String
        let expiresAt: String?

        let activeTasksLimit: Int?
        let activeTasksUsed: Int
        let chatLimitMonth: Int?
        let chatUsedMonth: Int
        let chatResetsAt: String?
        let gradeLimitWeek: Int?
        let gradeUsedWeek: Int
        let gradeResetsAt: String?
        let rubricsLimit: Int?
        let rubricsUsed: Int

        let toolsAccess: String
        let curriculumIntelligence: Bool
        let advancedModels: Bool

        enum CodingKeys: String, CodingKey {
            case tier
            case displayName = "display_name"
            case priceCents = "price_cents"
            case currency
            case expiresAt = "expires_at"
            case activeTasksLimit = "active_tasks_limit"
            case activeTasksUsed = "active_tasks_used"
            case chatLimitMonth = "chat_limit_month"
            case chatUsedMonth = "chat_used_month"
            case chatResetsAt = "chat_resets_at"
            case gradeLimitWeek = "grade_limit_week"
            case gradeUsedWeek = "grade_used_week"
            case gradeResetsAt = "grade_resets_at"
            case rubricsLimit = "rubrics_limit"
            case rubricsUsed = "rubrics_used"
            case toolsAccess = "tools_access"
            case curriculumIntelligence = "curriculum_intelligence"
            case advancedModels = "advanced_models"
        }
    }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// `my_plan()` takes no arguments, so no user id is sent and there is
    /// nothing to filter by. That is what makes asking about somebody else
    /// impossible here rather than merely unauthorised.
    func fetch() async throws -> EntitlementService.Plan? {
        guard let client else { return nil }
        let rows: [Row] = try await client.rpc("my_plan").execute().value
        guard let row = rows.first else { return nil }

        return EntitlementService.Plan(
            tier: EntitlementService.Tier(rawValue: row.tier) ?? .free,
            displayName: row.displayName,
            priceCents: row.priceCents,
            currency: row.currency,
            expiresAt: PostgresTimestamp.parse(row.expiresAt),
            tasks: .init(limit: row.activeTasksLimit, used: row.activeTasksUsed),
            chat: .init(limit: row.chatLimitMonth, used: row.chatUsedMonth,
                        resetsAt: PostgresTimestamp.parse(row.chatResetsAt)),
            grader: .init(limit: row.gradeLimitWeek, used: row.gradeUsedWeek,
                          resetsAt: PostgresTimestamp.parse(row.gradeResetsAt)),
            rubrics: .init(limit: row.rubricsLimit, used: row.rubricsUsed),
            toolsAccess: EntitlementService.ToolsAccess(rawValue: row.toolsAccess) ?? .basic,
            curriculumIntelligence: row.curriculumIntelligence,
            advancedModels: row.advancedModels)
    }
}

/// Postgres timestamps, both variants.
///
/// `.withFractionalSeconds` and plain ISO8601 are separate formatter
/// configurations and each rejects the other's output, so a single formatter
/// silently loses every reset time the moment a row happens to land on a whole
/// second. Lifted out of `GradingService` when the meter grew a second caller.
enum PostgresTimestamp {
    static func parse(_ raw: String?) -> Date? {
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
