import Foundation
import Observation
import SwiftData
import AlbusCore

/// Runs one study session, and measures it honestly.
///
/// **Why this exists.** Completion used to be a checkbox: one tap recorded a
/// full session's worth of work. That is not a security hole — a student can
/// only lie to themselves — but it makes the estimator's input worthless, and
/// the estimator learning how long things really take is the product.
///
/// **What is measured, and how.** Elapsed time comes from
/// `ContinuousClock`, which counts real time forward and cannot be moved.
/// Wall-clock `Date` is stored for display and restoration, but never used to
/// decide how much focus has been earned: setting the device clock forward an
/// hour would otherwise complete any session instantly.
///
/// **What this deliberately does not do.** iOS does not let an app block other
/// apps. There is no API for it outside Screen Time's own parental controls,
/// and pretending otherwise would be a lie told by the UI. So Focus Mode keeps
/// the screen awake, notices when the student leaves, tells them when the timer
/// ends, and reports what actually happened. Honesty, not enforcement.
@Observable
@MainActor
final class FocusSession {

    enum Phase: Equatable {
        case idle
        case running
        case paused
        /// The timer reached the end. The session is complete and waiting to
        /// be acknowledged.
        case finished
    }

    private(set) var phase: Phase = .idle
    /// The session being run. Nil when idle.
    private(set) var record: PlanSessionRecord?
    /// Seconds of focus banked across previous runs plus the current one.
    private(set) var focusedSeconds: Int = 0
    private(set) var interruptions: Int = 0

    /// Total the session is aiming for.
    private(set) var targetSeconds: Int = 0

    var remainingSeconds: Int { max(0, targetSeconds - focusedSeconds) }

    var progress: Double {
        targetSeconds == 0 ? 0 : min(1, Double(focusedSeconds) / Double(targetSeconds))
    }

    /// Monotonic mark taken when the current run began. Not a Date on purpose.
    private var runStartedAt: ContinuousClock.Instant?
    /// Focus banked before the current run — so pausing does not lose time.
    private var bankedSeconds: Int = 0
    private var ticker: Task<Void, Never>?

    private let notifications: NotificationScheduler

    init(notifications: NotificationScheduler = NotificationScheduler()) {
        self.notifications = notifications
    }

    // MARK: - Lifecycle

    func start(_ session: PlanSessionRecord, context: ModelContext) {
        guard phase == .idle else { return }

        record = session
        // The target is the plan's own length, floored at a minute so a
        // degenerate row cannot produce a zero-length session that is
        // "complete" the instant it opens.
        targetSeconds = max(60, session.plannedSeconds)
        bankedSeconds = session.focusedSeconds ?? 0
        focusedSeconds = bankedSeconds
        interruptions = session.interruptions ?? 0

        if session.startedAt == nil { session.startedAt = .now }
        session.sessionState = .active
        try? context.save()

        resume()
    }

    func resume() {
        guard phase != .running, record != nil else { return }
        phase = .running
        runStartedAt = ContinuousClock.now
        bankedSeconds = focusedSeconds

        notifications.scheduleCompletion(in: remainingSeconds,
                                         title: record?.subtask?.title ?? "Study session")
        startTicking()
    }

    func pause() {
        guard phase == .running else { return }
        bank()
        phase = .paused
        ticker?.cancel()
        ticker = nil
        notifications.cancelCompletion()
    }

    /// The app went to the background. The timer keeps running — leaving does
    /// not cost the student their progress — but it is recorded, because a
    /// session spent in another app is not the same as one spent working.
    func noteLeftApp() {
        guard phase == .running else { return }
        interruptions += 1
    }

    /// Ends the session and writes down what actually happened.
    ///
    /// - Parameter completedWork: whether the *step* is done, which is the
    ///   student's call. The measured duration is not.
    @discardableResult
    func finish(completedWork: Bool, context: ModelContext,
                coordinator: PlanCoordinator,
                availability: Availability) -> Int {
        bank()
        ticker?.cancel()
        ticker = nil
        notifications.cancelCompletion()

        guard let session = record else {
            phase = .idle
            return 0
        }

        session.focusedSeconds = focusedSeconds
        session.interruptions = interruptions
        session.endedAt = .now
        session.sessionState = completedWork ? .completed : .scheduled

        if completedWork, let subtask = session.subtask {
            // Re-flows the rest of the plan around what actually happened.
            coordinator.setCompleted(subtask, true, context: context,
                                     availability: availability)
        } else {
            try? context.save()
        }

        let measured = focusedSeconds
        reset()
        return measured
    }

    /// Leaves the session as it stands, banking the time without completing.
    func cancel(context: ModelContext) {
        bank()
        ticker?.cancel()
        ticker = nil
        notifications.cancelCompletion()

        if let session = record {
            session.focusedSeconds = focusedSeconds
            session.interruptions = interruptions
            // Back to scheduled: a session left partway is still to do.
            session.sessionState = .scheduled
            try? context.save()
        }
        reset()
    }

    // MARK: - Internals

    /// Moves elapsed monotonic time into the banked total.
    private func bank() {
        guard let started = runStartedAt else { return }
        let elapsed = Int(ContinuousClock.now.components(since: started).seconds)
        focusedSeconds = bankedSeconds + max(0, elapsed)
        runStartedAt = nil
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            // One second is enough for a countdown and cheap enough to run for
            // an hour. The value shown is derived from the clock each tick, so
            // a dropped tick shows the right number rather than drifting.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase == .running else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let started = runStartedAt else { return }
        let elapsed = Int(ContinuousClock.now.components(since: started).seconds)
        focusedSeconds = bankedSeconds + max(0, elapsed)

        if focusedSeconds >= targetSeconds {
            focusedSeconds = targetSeconds
            phase = .finished
            ticker?.cancel()
            ticker = nil
        }
    }

    private func reset() {
        phase = .idle
        record = nil
        focusedSeconds = 0
        bankedSeconds = 0
        interruptions = 0
        targetSeconds = 0
        runStartedAt = nil
    }
}

extension ContinuousClock.Instant {
    /// Seconds since a mark, as an integer.
    func components(since start: ContinuousClock.Instant) -> (seconds: Int, attoseconds: Int64) {
        let duration = start.duration(to: self)
        let parts = duration.components
        return (Int(parts.seconds), parts.attoseconds)
    }
}
