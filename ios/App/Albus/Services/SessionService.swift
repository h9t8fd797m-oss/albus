import Foundation
import Supabase

/// Gets the user signed in, silently, before anything else runs.
///
/// Albus has no sign-up screen: every user is anonymous from first launch.
/// That is a product decision (a signup wall is the single biggest thing that
/// kills apps like this) but it is also why the session must be durable — the
/// anonymous account *is* the account, and losing it loses their work and
/// resets their free quota.
@Observable
@MainActor
final class SessionService {

    enum State: Equatable {
        case starting
        case signedIn(userID: UUID, isAnonymous: Bool)
        case failed(String)
    }

    private(set) var state: State = .starting

    var userID: UUID? {
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// Restores an existing session, or creates an anonymous one.
    ///
    /// Restore is tried first and deliberately: signing in again when a valid
    /// session already exists would orphan the previous account and hand the
    /// caller a clean quota, which is exactly the abuse the Keychain-backed
    /// session exists to prevent.
    func start() async {
        guard let client else {
            state = .failed("Not configured")
            return
        }
        do {
            let session = try await client.auth.session
            state = .signedIn(userID: session.user.id,
                              isAnonymous: session.user.isAnonymous)
            return
        } catch {
            // No stored session, or it could not be refreshed. Fall through.
        }

        do {
            let session = try await client.auth.signInAnonymously()
            state = .signedIn(userID: session.user.id,
                              isAnonymous: session.user.isAnonymous)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "No connection."
        }
        return error.localizedDescription
    }
}
