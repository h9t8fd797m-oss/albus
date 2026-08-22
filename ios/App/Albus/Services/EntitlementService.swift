import Foundation
import Supabase
import AlbusCore

/// Whether this student is on Plus.
///
/// **Read-only, and asked of the server.** The app never decides its own tier
/// and never caches it as a durable fact: `entitlements` is server-written,
/// clients hold only a SELECT grant, and every limit that matters is enforced
/// again inside the database on each call. This exists to show the right UI,
/// not to gate anything — a tampered value here buys a nicer paywall and
/// nothing else.
@Observable
@MainActor
final class EntitlementService {

    enum Tier: String, Sendable {
        case free, plus
    }

    struct Entitlement: Decodable, Sendable {
        let tier: String
        let expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case tier
            case expiresAt = "expires_at"
        }
    }

    private(set) var tier: Tier = .free
    private(set) var expiresAt: Date?
    private(set) var lastCheckedAt: Date?

    /// True only while a paid period is genuinely current. An expiry in the
    /// past is free, whatever the row says — the same `coalesce`-and-compare
    /// the database does, so the two cannot disagree about what a stale row
    /// means.
    var isPlus: Bool {
        guard tier == .plus else { return false }
        guard let expiresAt else { return true }
        return expiresAt > .now
    }

    private let reader: EntitlementReader

    init(reader: EntitlementReader = EntitlementReader()) {
        self.reader = reader
    }

    /// Refreshes from the server. Failure leaves the previous value alone
    /// rather than downgrading: a dropped connection must not make a paying
    /// student look free.
    func refresh() async {
        do {
            let row = try await reader.fetch()
            if let row {
                tier = Tier(rawValue: row.tier) ?? .free
                expiresAt = row.expiresAt
            } else {
                // No row at all means nobody has ever bought anything.
                tier = .free
                expiresAt = nil
            }
            lastCheckedAt = .now
        } catch {
            print("[Albus] entitlement refresh failed: \(error.localizedDescription)")
        }
    }
}

/// The network half, deliberately outside the MainActor class.
///
/// `PostgrestResponse` is not Sendable, so awaiting `.execute()` from an
/// actor-isolated method means returning a non-Sendable value across an
/// isolation boundary — which Xcode 16.4 rejects and Xcode 26 allows. Keeping
/// the request in a plain nonisolated type means only the decoded, Sendable
/// row ever crosses. Same shape as PlanService, for the same reason.
struct EntitlementReader: Sendable {
    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// RLS restricts this to the caller's own row, so there is nothing to
    /// filter by — and no user id is sent, which is what makes it impossible
    /// to ask about anyone else.
    func fetch() async throws -> EntitlementService.Entitlement? {
        guard let client else { return nil }
        let rows: [EntitlementService.Entitlement] = try await client
            .from("entitlements")
            .select("tier, expires_at")
            .limit(1)
            .execute()
            .value
        return rows.first
    }
}
