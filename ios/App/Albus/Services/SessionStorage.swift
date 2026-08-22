import Foundation
import Supabase

/// Where the auth session is kept between launches.
///
/// Keychain is the right home: its items survive app deletion on iOS, which is
/// what stops "delete and reinstall" handing out a fresh free-tier quota.
///
/// But Keychain writes fail with `errSecMissingEntitlement` (-34018) on a build
/// without a signed `keychain-access-groups` entitlement — which is every
/// simulator build until there is an Apple Team ID. The Supabase client treats
/// that write failure as a sign-in failure, so the app could not sign in at
/// all. Discovered by a probe that wrote one value and read it back.
///
/// So: use Keychain, and fall back to UserDefaults only when Keychain is
/// genuinely unavailable. The fallback is weaker — it does not survive app
/// deletion, and it is readable from a device backup — so it is used only when
/// the alternative is no session at all, and it says so once in the log.
///
/// Quota enforcement does not rest on this. The global spend fuse in migration
/// 0013 bounds abuse regardless of how many accounts exist.
struct ResilientAuthStorage: AuthLocalStorage {

    private let keychain: KeychainLocalStorage
    /// `UserDefaults` is not `Sendable`, but it is documented as thread-safe.
    /// Held as an unchecked box rather than made global state so tests can
    /// inject an isolated suite instead of sharing `.standard`.
    private let fallbackBox: UncheckedBox<UserDefaults>
    private let fallbackPrefix = "albus.auth."

    private var fallback: UserDefaults { fallbackBox.value }

    init(service: String = "com.felipegutierrez.albus.auth",
         fallback: UserDefaults = .standard) {
        self.keychain = KeychainLocalStorage(service: service)
        self.fallbackBox = UncheckedBox(fallback)
    }

    func store(key: String, value: Data) throws {
        do {
            try keychain.store(key: key, value: value)
            // Clear any earlier fallback copy so there is one source of truth.
            fallback.removeObject(forKey: fallbackPrefix + key)
        } catch {
            Self.warnOnce(error)
            fallback.set(value, forKey: fallbackPrefix + key)
        }
    }

    func retrieve(key: String) throws -> Data? {
        // `data != nil` used to sit here and always be true — retrieve returns
        // a non-optional. Emptiness is the real question: an empty blob is not
        // a session, and returning it would skip the fallback that holds one.
        if let data = try? keychain.retrieve(key: key), !data.isEmpty {
            return data
        }
        return fallback.data(forKey: fallbackPrefix + key)
    }

    func remove(key: String) throws {
        try? keychain.remove(key: key)
        fallback.removeObject(forKey: fallbackPrefix + key)
    }

    private static let warned = NSLock()
    nonisolated(unsafe) private static var hasWarned = false

    /// Once, not per write — a failing Keychain fails on every single call.
    private static func warnOnce(_ error: Error) {
        warned.lock()
        defer { warned.unlock() }
        guard !hasWarned else { return }
        hasWarned = true
        print("""
        [Albus] Keychain unavailable (\(error)); falling back to UserDefaults.
        The session will not survive app deletion. Expected on unsigned
        simulator builds — set DEVELOPMENT_TEAM to restore Keychain storage.
        """)
    }
}


/// Narrow escape hatch for a type Apple documents as thread-safe but has not
/// annotated `Sendable`. Confined to this file on purpose.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
