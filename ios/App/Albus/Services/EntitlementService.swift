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

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// Refreshes from the server. Failure leaves the previous value alone
    /// rather than downgrading: a dropped connection must not make a paying
    /// student look free.
    func refresh() async {
        guard let client else { return }
        do {
            let rows: [Entitlement] = try await client
                .from("entitlements")
                .select("tier, expires_at")
                .limit(1)
                .execute()
                .value

            // RLS restricts this to the caller's own row, so there is nothing
            // to filter by — and no user_id is sent, which is what makes it
            // impossible to ask about someone else.
            if let row = rows.first {
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
