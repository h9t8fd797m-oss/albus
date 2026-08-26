import Foundation
import AlbusCore

/// Bookkeeping the notification rebuild needs and nobody else should see.
///
/// Separate from `Preferences` on purpose: that type is documented as "what the
/// student told us about themselves", and a digest of the last scheduled set is
/// not that. Keeping them apart means a student-facing setting screen never has
/// to reason about a fire log.
///
/// **Takes an injected `UserDefaults`**, unlike `PendingDeletions`, which
/// hardcodes `.standard` — and whose test consequently writes into the real
/// defaults. Swift Testing runs suites in parallel, so two suites sharing
/// `.standard` would flake against each other.
@MainActor
final class NotificationState {

    private enum Key {
        static let digest = "albus.notify.digest"
        static let fireLog = "albus.notify.fireLog"
        static let lastOpened = "albus.notify.lastOpened"
        static let ignoredStreak = "albus.notify.ignoredStreak"
        static let pausedUntil = "albus.notify.pausedUntil"
        static let unfitSignature = "albus.notify.unfitSignature"
    }

    /// Consecutive unattended notifications before Albus stops nudging.
    static let ignoreLimit = 5
    static let pauseDays = 14
    /// How soon after a notification an app open counts as a response.
    private static let engagementWindow: TimeInterval = 30 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - The diff's early-out

    /// Hash of the last set actually scheduled.
    ///
    /// Most re-flows move a block by forty-five minutes and change no
    /// notification at all. Comparing one string is what keeps eight
    /// `reschedule` call sites from each costing a round trip to the daemon.
    var digest: String {
        get { defaults.string(forKey: Key.digest) ?? "" }
        set { defaults.set(newValue, forKey: Key.digest) }
    }

    /// The last unplaceable signature Albus alarmed about.
    var unfitSignature: String {
        get { defaults.string(forKey: Key.unfitSignature) ?? "" }
        set { defaults.set(newValue, forKey: Key.unfitSignature) }
    }

    // MARK: - Engagement

    var lastOpened: Date {
        get {
            let stored = defaults.double(forKey: Key.lastOpened)
            return stored > 0 ? Date(timeIntervalSince1970: stored) : .distantPast
        }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastOpened) }
    }

    var pausedUntil: Date? {
        get {
            let stored = defaults.double(forKey: Key.pausedUntil)
            return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.pausedUntil) }
    }

    private(set) var ignoredStreak: Int {
        get { defaults.integer(forKey: Key.ignoredStreak) }
        set { defaults.set(newValue, forKey: Key.ignoredStreak) }
    }

    /// When each pending notification is due to fire.
    ///
    /// There is no delivery receipt for a local notification, so this is how
    /// Albus can tell it was ignored: a fire time that passed with no app open
    /// shortly after.
    private var fireLog: [TimeInterval] {
        get { defaults.array(forKey: Key.fireLog) as? [TimeInterval] ?? [] }
        set { defaults.set(newValue, forKey: Key.fireLog) }
    }

    func recordScheduled(_ dates: [Date], now: Date) {
        // Two weeks is long enough to judge a streak and short enough that the
        // list cannot grow without bound.
        let cutoff = now.addingTimeInterval(-14 * 86_400).timeIntervalSince1970
        let merged = Set(fireLog + dates.map(\.timeIntervalSince1970))
        fireLog = merged.filter { $0 > cutoff }.sorted()
    }

    /// Records that the app came to the front, and re-scores the streak.
    ///
    /// An open shortly after a fire time clears the streak entirely: the point
    /// is whether Albus is being listened to, and one response means yes.
    func recordAppOpen(now: Date) {
        let previous = lastOpened
        lastOpened = now

        let unattended = fireLog
            .map { Date(timeIntervalSince1970: $0) }
            .filter { $0 > previous && $0 <= now }

        guard !unattended.isEmpty else { return }

        let answered = unattended.contains { now.timeIntervalSince($0) <= Self.engagementWindow }
        ignoredStreak = answered ? 0 : ignoredStreak + unattended.count

        if answered {
            // Any sign of life ends the pause. A student who came back should
            // not stay muted for another fortnight.
            pausedUntil = nil
        } else if ignoredStreak >= Self.ignoreLimit, pausedUntil == nil {
            pausedUntil = now.addingTimeInterval(TimeInterval(Self.pauseDays) * 86_400)
        }
    }

    /// A tap is the clearest possible signal that this is working.
    func recordEngagement(now: Date) {
        ignoredStreak = 0
        pausedUntil = nil
        lastOpened = now
    }

    /// Only for tests and for a student switching notifications off and on.
    func reset() {
        for key in [Key.digest, Key.fireLog, Key.lastOpened,
                    Key.ignoredStreak, Key.pausedUntil, Key.unfitSignature] {
            defaults.removeObject(forKey: key)
        }
    }
}
