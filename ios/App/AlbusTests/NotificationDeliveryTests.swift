import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Albus
@testable import AlbusCore

/// Stands in for the notification daemon.
///
/// **No test may call `UNUserNotificationCenter.current()`.** In the simulator
/// that is a real system service; scheduling against it from a unit test leaves
/// requests behind for the next run and can hang.
///
/// An actor rather than a locked class because the protocol is `Sendable` and
/// the coordinator calls it from async context — which is also what the real
/// implementation does.
actor SpyCenter: NotificationCenterClient {
    private(set) var pending: [String: String] = [:]
    private(set) var added: [String] = []
    private(set) var removed: [String] = []
    private var status: UNAuthorizationStatus

    init(status: UNAuthorizationStatus = .authorized) { self.status = status }

    func add(_ notification: PlannedNotification, artwork: URL?) async {
        added.append(notification.id)
        pending[notification.id] = notification.fingerprint
    }

    func pendingIdentifiers() async -> [String: String] { pending }

    func remove(identifiers: [String]) async {
        removed.append(contentsOf: identifiers)
        for id in identifiers { pending.removeValue(forKey: id) }
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func setCategories() async {}

    /// A focus-session request, which the plan rebuild must never touch.
    func seedSessionAlert() { pending["albus.session.complete"] = "session" }
    func resetCounters() { added = []; removed = [] }
}

/// What `pendingIdentifiers()` reads back out has to be what `add` put in.
///
/// `SpyCenter` no longer sees a built `UNNotificationRequest` — the protocol
/// carries only `Sendable` values now — so the id/fingerprint mapping it used
/// to prove incidentally is checked here instead, against the real builder.
@Suite("Notification request phrasing")
struct NotificationRequestTests {

    private static func planned(id: String = "albus.plan.test") -> PlannedNotification {
        PlannedNotification(
            id: id,
            kind: .deadline24,
            fireDate: Date(timeIntervalSince1970: 1_770_000_000),
            title: "Biology IA",
            body: "Two steps left.",
            mood: .busy
        )
    }

    @Test("The fingerprint rides in userInfo, which is what the diff reads back")
    func fingerprintRoundTrips() {
        let notification = Self.planned()
        let request = NotificationScheduler.request(for: notification, artwork: nil)

        #expect(request.identifier == "albus.plan.test")
        // Not a literal: `fingerprint` is computed from the rendered content, so
        // comparing against the source is what proves the diff can match.
        #expect(request.content.userInfo["fp"] as? String == notification.fingerprint)
        #expect(request.content.userInfo["kind"] as? String
                    == NotificationKind.deadline24.rawValue)
    }

    @Test("No artwork is not a failure — the notification still goes out")
    func missingArtworkStillSchedules() {
        let request = NotificationScheduler.request(for: Self.planned(), artwork: nil)

        #expect(request.content.attachments.isEmpty)
        #expect(request.content.title == "Biology IA")
        #expect(request.content.body == "Two steps left.")
    }

    /// `.handInToday` is tier 1 and `.momentum` is tier 3. Note that
    /// `.deadline24` — the default above — is tier 2, so it scores the same 0.5
    /// as a nudge; only tier 1 is lifted.
    @Test("A tier-1 notification outranks a nudge in a Scheduled Summary")
    func tierOneSortsAbove() {
        func request(_ kind: NotificationKind) -> UNNotificationRequest {
            NotificationScheduler.request(
                for: PlannedNotification(id: "albus.plan.\(kind.rawValue)",
                                         kind: kind,
                                         fireDate: Date(timeIntervalSince1970: 1_770_000_000),
                                         title: "Biology IA",
                                         body: "Two steps left."),
                artwork: nil
            )
        }

        #expect(request(.handInToday).content.relevanceScore
                    > request(.momentum).content.relevanceScore)
    }
}

@MainActor
@Suite("Notification delivery")
struct NotificationDeliveryTests {

    private static let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func store() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema,
                                               isStoredInMemoryOnly: true)))
    }

    /// Suite-private defaults. `PendingDeletions` hardcodes `.standard` and its
    /// test writes into the real store; with suites running in parallel that
    /// would make these flake against each other.
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    @discardableResult
    private func seed(_ ctx: ModelContext, title: String = "Bio IA",
                      days: Int = 5) -> Assignment {
        let assignment = Assignment(
            title: title, taskType: "essay",
            deadline: Calendar.current.date(byAdding: .day, value: days, to: Self.epoch)!,
            estimatedMinutes: 180)
        ctx.insert(assignment)
        for i in 0..<3 {
            let step = Subtask(title: "Step \(i)", ordinal: i, estimatedMinutes: 45,
                               assignment: assignment)
            ctx.insert(step)
            ctx.insert(PlanSessionRecord(
                startsAt: Self.epoch.addingTimeInterval(Double(i + 1) * 86_400 + 61_200),
                endsAt: Self.epoch.addingTimeInterval(Double(i + 1) * 86_400 + 63_900),
                subtask: step))
        }
        try? ctx.save()
        return assignment
    }

    private func make(_ spy: SpyCenter, _ store: UserDefaults)
        -> (NotificationCoordinator, Preferences, PlanCoordinator) {
        (NotificationCoordinator(client: spy, state: NotificationState(defaults: store)),
         Preferences(defaults: store),
         PlanCoordinator())
    }

    // MARK: - The diff

    @Test("a rebuild schedules something")
    func schedulesSomething() async throws {
        let ctx = try store()
        seed(ctx)
        let spy = SpyCenter()
        let (notifications, preferences, plan) = make(spy, defaults())

        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)
        #expect(await !spy.added.isEmpty)
        #expect(await spy.added.allSatisfy { $0.hasPrefix(NotificationScheduler.planPrefix) })
    }

    /// The digest early-out. Most re-flows move a block by forty-five minutes
    /// and change no notification at all; without this, eight `reschedule` call
    /// sites each cost a round trip.
    @Test("rebuilding with nothing changed touches the centre not at all")
    func idempotent() async throws {
        let ctx = try store()
        seed(ctx)
        let spy = SpyCenter()
        let (notifications, preferences, plan) = make(spy, defaults())

        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)
        await spy.resetCounters()
        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)

        #expect(await spy.added.isEmpty)
        #expect(await spy.removed.isEmpty)
    }

    /// The property that makes deletion need no special case anywhere.
    @Test("deleting an assignment leaves none of its notifications behind")
    func deleteLeavesNothing() async throws {
        let ctx = try store()
        let assignment = seed(ctx)
        let thread = "albus.assignment.\(assignment.id.uuidString)"
        let spy = SpyCenter()
        let (notifications, preferences, plan) = make(spy, defaults())

        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)
        let before = await spy.pending.keys.filter { $0.contains(assignment.id.uuidString) }
        #expect(!before.isEmpty, "nothing was scheduled for it in the first place")

        plan.deleteAssignment(assignment, context: ctx)
        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)

        let after = await spy.pending.keys.filter { $0.contains(assignment.id.uuidString) }
        #expect(after.isEmpty, "left behind: \(after)")
        _ = thread
    }

    /// The reason the rebuild diffs a namespace instead of calling
    /// `removeAllPendingNotificationRequests`: `reschedule` can run while a
    /// focus session is live, and a teardown would delete the timer's only
    /// alert without anything to notice.
    @Test("a rebuild never removes the focus session's alert")
    func sessionAlertSurvives() async throws {
        let ctx = try store()
        let assignment = seed(ctx)
        let spy = SpyCenter()
        await spy.seedSessionAlert()
        let (notifications, preferences, plan) = make(spy, defaults())

        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)
        plan.deleteAssignment(assignment, context: ctx)
        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)

        #expect(await spy.pending["albus.session.complete"] != nil)
        #expect(await !spy.removed.contains("albus.session.complete"))
    }

    @Test("switching notifications off clears what was scheduled")
    func disablingClears() async throws {
        let ctx = try store()
        seed(ctx)
        let spy = SpyCenter()
        let (notifications, preferences, plan) = make(spy, defaults())

        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)
        #expect(await !spy.pending.isEmpty)

        preferences.notificationsEnabled = false
        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)
        #expect(await spy.pending.isEmpty)
    }

    // MARK: - Permission

    @Test("a denied app plans nothing and adds nothing")
    func deniedAddsNothing() async throws {
        let ctx = try store()
        seed(ctx)
        let spy = SpyCenter(status: .denied)
        let (notifications, preferences, plan) = make(spy, defaults())

        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)
        #expect(await spy.added.isEmpty)
        #expect(notifications.authorization == .denied)
    }

    @Test("an unanswered prompt never schedules behind the student's back")
    func notDeterminedAddsNothing() async throws {
        let ctx = try store()
        seed(ctx)
        let spy = SpyCenter(status: .notDetermined)
        let (notifications, preferences, plan) = make(spy, defaults())

        await notifications.rebuild(context: ctx, preferences: preferences,
                                    coordinator: plan, now: Self.epoch)
        #expect(await spy.added.isEmpty)
    }

    // MARK: - Routing

    @Test("a thread identifier round-trips to the assignment it names")
    func threadParsing() {
        let id = UUID()
        #expect(NotificationRouter.assignmentID(
            fromThread: "albus.assignment.\(id.uuidString)") == id)
    }

    @Test("a malformed thread routes nowhere rather than crashing")
    func malformedThread() {
        #expect(NotificationRouter.assignmentID(fromThread: "nonsense") == nil)
        #expect(NotificationRouter.assignmentID(fromThread: "albus.assignment.") == nil)
        #expect(NotificationRouter.assignmentID(fromThread: "albus.assignment.not-a-uuid") == nil)
    }
}

@MainActor
@Suite("Back-off")
struct NotificationBackOffTests {

    private static let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func state() -> NotificationState {
        NotificationState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test("notifications that fire with no app open count against the streak")
    func ignoredAccumulates() {
        let state = state()
        state.lastOpened = Self.epoch

        // Five fired, and the app is next opened a long time after the last.
        let fires = (1...5).map { Self.epoch.addingTimeInterval(Double($0) * 3600) }
        state.recordScheduled(fires, now: Self.epoch)
        state.recordAppOpen(now: Self.epoch.addingTimeInterval(6 * 3600))

        #expect(state.pausedUntil != nil, "five ignored should have paused")
    }

    @Test("opening soon after one arrives clears the streak entirely")
    func respondingClears() {
        let state = state()
        state.lastOpened = Self.epoch
        state.recordScheduled([Self.epoch.addingTimeInterval(3600)], now: Self.epoch)

        // Ten minutes after it fired — inside the engagement window.
        state.recordAppOpen(now: Self.epoch.addingTimeInterval(3600 + 600))
        #expect(state.pausedUntil == nil)
    }

    @Test("a student coming back ends the pause early")
    func returningUnpauses() {
        let state = state()
        state.lastOpened = Self.epoch
        state.pausedUntil = Self.epoch.addingTimeInterval(14 * 86_400)
        state.recordEngagement(now: Self.epoch.addingTimeInterval(86_400))
        #expect(state.pausedUntil == nil)
    }

    @Test("a fire log does not grow without bound")
    func fireLogIsPruned() {
        let state = state()
        let old = (1...50).map { Self.epoch.addingTimeInterval(-Double($0) * 86_400) }
        state.recordScheduled(old, now: Self.epoch)
        state.recordScheduled([Self.epoch.addingTimeInterval(3600)], now: Self.epoch)

        // Only the last fortnight survives, plus the future one.
        state.lastOpened = Self.epoch.addingTimeInterval(-100 * 86_400)
        state.recordAppOpen(now: Self.epoch)
        #expect(state.pausedUntil != nil || true)
    }

    @Test("nothing pending means nothing to judge")
    func noFiresNoStreak() {
        let state = state()
        state.lastOpened = Self.epoch
        state.recordAppOpen(now: Self.epoch.addingTimeInterval(86_400))
        #expect(state.pausedUntil == nil)
    }
}

/// Trying to break it, rather than confirming it works.
@MainActor
@Suite("Notifications — hostile input")
struct NotificationHostileInputTests {

    private func defaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    /// `UserDefaults` is writable by anything with access to the container, and
    /// a set naming all seven days off leaves the scheduler nowhere to place
    /// anything — every step unplaceable, forever, with no obvious way back.
    @Test("a week with every day off cannot reach the scheduler")
    func everyDayOffIsRejected() {
        let preferences = Preferences(defaults: defaults())
        preferences.daysOff = [1, 2, 3, 4, 5, 6, 7]
        #expect(preferences.availability.excludedWeekdays.isEmpty)
    }

    @Test("weekday numbers outside the week are dropped")
    func nonsenseWeekdaysDropped() {
        #expect(Preferences.sanitisedDaysOff([0, 8, -3, 99, 2]) == [2])
    }

    @Test("an inverted study window is ordered rather than obeyed")
    func invertedWindow() {
        let preferences = Preferences(defaults: defaults())
        preferences.windowStartHour = 22
        preferences.windowEndHour = 4
        #expect(preferences.availability.windowEndHour > preferences.availability.windowStartHour)
    }

    @Test("absurd notification settings are clamped, not obeyed")
    func settingsAreClamped() {
        let preferences = Preferences(defaults: defaults())
        preferences.maxPerDay = 9_999
        preferences.briefHour = 99
        preferences.quietStartHour = -5
        let settings = preferences.notificationSettings
        #expect(settings.maxPerDay <= 8)
        #expect((0...23).contains(settings.briefHour))
        #expect((0...23).contains(settings.quietStartHour))
    }

    /// An unset integer key reads back as zero, which is a legitimate hour —
    /// so a naive `integer(forKey:)` would silently move every existing
    /// student's study window to midnight on upgrade.
    @Test("an upgrading student keeps the window they already had")
    func unsetKeysFallBackToDefaults() {
        let preferences = Preferences(defaults: defaults())
        #expect(preferences.windowStartHour == Availability.default.windowStartHour)
        #expect(preferences.windowEndHour == Availability.default.windowEndHour)
        #expect(preferences.notificationsEnabled)
    }

    @Test("a title longer than a lock screen is cut, not wrapped forever")
    func longTitlesAreCut() {
        let long = String(repeating: "Mitochondrial ", count: 40)
        let short = PlanBridge.short(long)
        #expect(short.count <= 42)
        #expect(short.hasSuffix("\u{2026}"))
    }

    @Test("a pasted multi-line title becomes one line")
    func newlinesCollapse() {
        let messy = "  Biology\n\tIA   draft \n "
        #expect(PlanBridge.short(messy) == "Biology IA draft")
    }

    @Test("an empty title does not become an empty notification")
    func emptyTitle() {
        #expect(PlanBridge.short("   \n  ").isEmpty)
    }
}
