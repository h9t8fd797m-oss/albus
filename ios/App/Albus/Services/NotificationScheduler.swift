import Foundation
import UserNotifications

/// Tells the student when a focus session has finished.
///
/// This is the only reason Albus asks for notification permission, and it is
/// asked for at the moment it is needed — the first time a session starts —
/// rather than on launch, where the answer is almost always no.
///
/// A timer that only exists while the app is open is not a study timer: the
/// phone goes face-down, the student works on paper, and nothing tells them
/// when to stop. The local notification is what makes Focus Mode usable.
struct NotificationScheduler: Sendable {

    /// One identifier, reused: there is only ever one session running, so
    /// scheduling a new completion replaces any stale one rather than stacking.
    private static let completionID = "albus.session.complete"

    /// Resolved per call rather than stored.
    ///
    /// `UNUserNotificationCenter` is not Sendable, so holding one would stop
    /// this type crossing an isolation boundary — and it is created inside an
    /// @Observable @MainActor class and used from async work. `current()` is a
    /// cheap singleton lookup, so there is nothing to gain by keeping it.
    private var center: UNUserNotificationCenter { .current() }

    /// Asks for permission, returning whether it was granted.
    ///
    /// Never throws upward: a refused prompt must not stop a session starting.
    /// The session still runs and still shows its countdown; the student just
    /// has to be looking.
    ///
    /// **`.badge` is requested even though nothing sets one yet, and that is a
    /// one-way door.** iOS shows the permission sheet once; a later call asking
    /// for options the student was never asked about does not re-prompt and
    /// does not grant them. Adding it after the first release would mean every
    /// existing student is permanently unable to receive a badge. It costs
    /// nothing now — the sheet looks identical to the student either way.
    @discardableResult
    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// What the student has actually granted.
    ///
    /// Everything that schedules has to be able to ask this: `add` succeeds
    /// while unauthorised and the request simply never presents, so without
    /// checking, a denied app looks identical to a working one from the inside.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Fires once, when the session's remaining time runs out.
    func scheduleCompletion(in seconds: Int, title: String) {
        cancelCompletion()
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Session finished"
        // The step's own name, so a glance at the lock screen says what is done.
        content.body = title
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(seconds), repeats: false
        )
        center.add(UNNotificationRequest(identifier: Self.completionID,
                                         content: content, trigger: trigger))
    }

    /// Pausing, ending early or finishing in-app all make the pending alert
    /// wrong. Removing it is what stops a notification arriving for a session
    /// the student already closed.
    func cancelCompletion() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.completionID])
    }
}
