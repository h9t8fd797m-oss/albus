import Foundation
import Supabase

/// The app's single connection to Supabase.
///
/// Configuration comes from the build's Info.plist, populated from
/// `Config.xcconfig` — which is gitignored. The publishable key is designed to
/// be public (RLS is what protects data, not the key), but keeping it out of
/// source means it can be rotated without a code change.
enum Backend {

    enum ConfigError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let k):
                "\(k) is not set. Copy App/Config.example.xcconfig to Config.xcconfig and fill it in."
            }
        }
    }

    /// `nil` when the build has no real configuration.
    ///
    /// This used to `fatalError`, which crashed the app on launch — including
    /// in CI, where placeholder values are expected and the app is the test
    /// host. Crashing is also the wrong product behaviour: an app that says
    /// "not signed in: not configured" is strictly better than one that dies
    /// before drawing a frame.
    static let shared: SupabaseClient? = {
        do {
            return try makeClient()
        } catch {
            print("[Albus] \(error.localizedDescription)")
            return nil
        }
    }()

    private static func makeClient() throws -> SupabaseClient {
        let info = Bundle.main.infoDictionary ?? [:]

        guard let raw = info["SUPABASE_URL"] as? String,
              !raw.isEmpty, !raw.contains("YOUR_PROJECT_REF"),
              let url = URL(string: raw)
        else { throw ConfigError.missing("SUPABASE_URL") }

        guard let key = info["SUPABASE_PUBLISHABLE_KEY"] as? String,
              !key.isEmpty, !key.hasSuffix("xxxxxxxxxxxxxxxxxxxx")
        else { throw ConfigError.missing("SUPABASE_PUBLISHABLE_KEY") }

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: .init(
                auth: .init(
                    // Keychain where available (survives app deletion, so a
                    // reinstall cannot reset the free quota), UserDefaults only
                    // when Keychain is genuinely unavailable. See the type.
                    storage: ResilientAuthStorage(),
                    autoRefreshToken: true
                )
            )
        )
    }
}
