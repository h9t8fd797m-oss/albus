import Testing
import Foundation
@testable import Albus

/// The session must round-trip whether or not Keychain is available.
///
/// Written after discovering that a Keychain write failure
/// (`errSecMissingEntitlement`) did not merely lose persistence — it made
/// sign-in fail outright, so the app could not reach the backend at all.
@Suite("Session storage")
struct SessionStorageTests {

    private func isolated() -> UserDefaults {
        UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!
    }

    @Test("a session round-trips even with no Keychain entitlement")
    func roundTrips() throws {
        let storage = ResilientAuthStorage(fallback: isolated())
        let value = Data("session-bytes".utf8)
        try storage.store(key: "session", value: value)
        #expect(try storage.retrieve(key: "session") == value)
    }

    @Test("a new instance reads what an earlier one wrote")
    func survivesNewInstance() throws {
        // The app builds fresh storage on every launch; if this fails, the
        // session cannot be restored and every launch creates a new account.
        let shared = isolated()
        let value = Data("session-bytes".utf8)
        try ResilientAuthStorage(fallback: shared).store(key: "session", value: value)
        #expect(try ResilientAuthStorage(fallback: shared).retrieve(key: "session") == value)
    }

    @Test("removal clears both stores, so sign-out really signs out")
    func removalIsComplete() throws {
        let shared = isolated()
        let storage = ResilientAuthStorage(fallback: shared)
        try storage.store(key: "session", value: Data("x".utf8))
        try storage.remove(key: "session")
        #expect(try storage.retrieve(key: "session") == nil)
    }

    @Test("a missing key returns nil rather than throwing")
    func missingKeyIsNotAnError() throws {
        let storage = ResilientAuthStorage(fallback: isolated())
        #expect(try storage.retrieve(key: "never-written") == nil)
    }
}
