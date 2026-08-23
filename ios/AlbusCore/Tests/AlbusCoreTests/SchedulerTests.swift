import Testing
import Foundation
@testable import AlbusCore

/// Fixed clock so every case is reproducible. Wed 20 May 2026, 09:00 local.
private let cal = Scheduler.defaultCalendar
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour, minute: minute))!
}
private let now = at(20, 9)
private let assignment = UUID()

private func item(_ minutes: Int, dueDay: Int, dueHour: Int = 23,
                  ordinal: Int = 0, assignment: UUID = assignment) -> ScheduleItem {
    ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: ordinal,
                 minutes: minutes, deadline: at(dueDay, dueHour))
}

private let sched = Scheduler()

@Suite("Placement")
struct PlacementTests {

    @Test("places work inside the study window")
    func placesInWindow() {
        let r = sched.schedule(items: [item(60, dueDay: 22)], now: now)
        #expect(r.sessions.count == 1)
        let s = r.sessions[0]
        #expect(cal.component(.hour, from: s.start) >= 16)
        #expect(cal.component(.hour, from: s.end) <= 22)
        #expect(r.unplaceable.isEmpty)
    }

    @Test("never schedules into the past")
    func neverPast() {
        let late = at(20, 18)   // 18:00, window already open
        let r = sched.schedule(items: [item(60, dueDay: 20)], now: late)
        for s in r.sessions { #expect(s.start >= late) }
    }

    @Test("respects the deadline")
    func respectsDeadline() {
        let r = sched.schedule(items: [item(60, dueDay: 21, dueHour: 18)], now: now)
        for s in r.sessions { #expect(s.end <= at(21, 18)) }
    }

    @Test("work due in the past cannot be placed")
    func pastDeadline() {
        let r = sched.schedule(items: [item(60, dueDay: 19)], now: now)
        #expect(r.sessions.isEmpty)
        #expect(r.unplaceable.count == 1)
    }

    @Test("routes around fixed commitments, never through them")
    func routesAroundCommitments() {
        let klass = FixedCommitment(start: at(20, 16), end: at(20, 21))
        let r = sched.schedule(items: [item(60, dueDay: 20)],
                               commitments: [klass], now: now)
        for s in r.sessions {
            #expect(!(s.start < klass.end && s.end > klass.start), "overlapped a class")
        }
    }

    @Test("earliest deadline is scheduled first")
    func deadlineOrder() {
        let soon = item(60, dueDay: 21, ordinal: 9)
        let later = item(60, dueDay: 25, ordinal: 0)
        let r = sched.schedule(items: [later, soon], now: now)
        let first = r.sessions.min { $0.start < $1.start }
        #expect(first?.itemID == soon.id)
    }

    @Test("steps of one assignment keep their order")
    func ordinalOrder() {
        let a = item(30, dueDay: 25, ordinal: 0)
        let b = item(30, dueDay: 25, ordinal: 1)
        let c = item(30, dueDay: 25, ordinal: 2)
        let r = sched.schedule(items: [c, a, b], now: now)
        let byStart = r.sessions.sorted { $0.start < $1.start }.map(\.itemID)
        #expect(byStart == [a.id, b.id, c.id])
    }

    @Test("daily capacity is not exceeded")
    func capacityRespected() {
        let av = Availability(windowStartHour: 8, windowEndHour: 23, dailyCapacityMinutes: 120)
        let items = (0..<6).map { item(60, dueDay: 30, ordinal: $0) }
        let r = sched.schedule(items: items, availability: av, now: now)
        var perDay: [Date: TimeInterval] = [:]
        for s in r.sessions { perDay[cal.startOfDay(for: s.start), default: 0] += s.duration }
        for (_, used) in perDay { #expect(used <= 120 * 60) }
    }

    @Test("excluded weekdays stay empty")
    func excludedWeekdays() {
        // 24 May 2026 is a Sunday.
        let av = Availability(excludedWeekdays: [1])
        let items = (0..<10).map { item(60, dueDay: 30, ordinal: $0) }
        let r = sched.schedule(items: items, availability: av, now: now)
        for s in r.sessions {
            #expect(cal.component(.weekday, from: s.start) != 1)
        }
    }

    @Test("sessions never overlap each other")
    func noSelfOverlap() {
        let items = (0..<12).map { item(45, dueDay: 30, ordinal: $0) }
        let r = sched.schedule(items: items, now: now)
        let sorted = r.sessions.sorted { $0.start < $1.start }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(a.end <= b.start, "sessions overlapped")
        }
    }
}

@Suite("Stability — the property users feel")
struct StabilityTests {

    @Test("a missed session moves as little as possible")
    func missMovesLittle() {
        let items = (0..<8).map { item(45, dueDay: 30, ordinal: $0) }
        let first = sched.schedule(items: items, now: now)

        // A day passes; one session was missed, the rest are untouched.
        let later = at(21, 9)
        var existing = first.sessions
        if let i = existing.indices.first(where: { existing[$0].start < later }) {
            existing[i].state = .missed
        }
        let second = sched.schedule(items: items, existing: existing, now: later)

        #expect(second.movedCount <= 1, "a single miss disturbed \(second.movedCount) blocks")
    }

    @Test("completed work is never rewritten")
    func completedPinned() {
        let it = item(60, dueDay: 25)
        let done = PlannedSession(itemID: it.id, assignmentID: assignment,
                                  start: at(20, 10), end: at(20, 11), state: .completed)
        let r = sched.schedule(items: [it], existing: [done], now: at(20, 12))
        #expect(r.sessions.contains { $0.id == done.id && $0.start == done.start })
        #expect(r.sessions.count == 1, "re-placed work that was already done")
    }

    @Test("a session in progress is not moved out from under the student")
    func activePinned() {
        let it = item(60, dueDay: 25)
        let active = PlannedSession(itemID: it.id, assignmentID: assignment,
                                    start: at(20, 8, 30), end: at(20, 9, 30), state: .active)
        let r = sched.schedule(items: [it], existing: [active], now: now)
        #expect(r.sessions.contains { $0.id == active.id && $0.start == active.start })
    }

    @Test("re-placed work keeps its identity so the UI can animate a move")
    func preservesIdentity() {
        let it = item(60, dueDay: 30)
        let first = sched.schedule(items: [it], now: now)
        let original = first.sessions[0]
        // A new class appears exactly where the session was.
        let wall = FixedCommitment(start: original.start, end: original.end.addingTimeInterval(3600))
        let second = sched.schedule(items: [it], existing: first.sessions,
                                    commitments: [wall], now: now)
        #expect(second.sessions.first?.id == original.id, "identity lost on re-place")
        #expect(second.sessions.first?.start != original.start)
    }

    @Test("identical input produces identical output")
    func deterministic() {
        let items = (0..<20).map { item(30, dueDay: 28, ordinal: $0) }
        let a = sched.schedule(items: items, now: now)
        let b = sched.schedule(items: items, now: now)
        #expect(a.sessions.map(\.start) == b.sessions.map(\.start))
        #expect(a.workload == b.workload)
    }
}

@Suite("Overload")
struct OverloadTests {

    @Test("work that cannot fit is surfaced, never dropped")
    func surfacesOverload() {
        // 20 hours due tomorrow, against a 2.5h/day capacity.
        let items = (0..<20).map { item(60, dueDay: 21, ordinal: $0) }
        let r = sched.schedule(items: items, now: now)
        #expect(!r.unplaceable.isEmpty)
        #expect(r.sessions.count + r.unplaceable.count == items.count,
                "work vanished: neither placed nor reported")
        #expect(r.workload == .cooked)
    }

    @Test("a light week reads as calm")
    func calm() {
        let r = sched.schedule(items: [item(30, dueDay: 30)], now: now)
        #expect(r.workload == .calm)
    }

    @Test("a full day reads as cooked even when everything fits")
    func busyToCooked() {
        let av = Availability(windowStartHour: 8, windowEndHour: 23, dailyCapacityMinutes: 120)
        let r = sched.schedule(items: [item(115, dueDay: 21)], availability: av, now: now)
        #expect(r.unplaceable.isEmpty)
        #expect(r.workload == .cooked)
    }

    @Test("zero capacity places nothing and says so")
    func zeroCapacity() {
        let av = Availability(dailyCapacityMinutes: 0)
        let r = sched.schedule(items: [item(30, dueDay: 30)], availability: av, now: now)
        #expect(r.sessions.isEmpty)
        #expect(r.unplaceable.count == 1)
        #expect(r.workload == .cooked)
    }
}

@Suite("Hostile input")
struct HostileInputTests {

    @Test("no items is not an error")
    func empty() {
        let r = sched.schedule(items: [], now: now)
        #expect(r.sessions.isEmpty)
        #expect(r.workload == .calm)
    }

    @Test("a commitment with inverted times cannot swallow the day")
    func invertedCommitment() {
        let bad = FixedCommitment(start: at(20, 20), end: at(20, 10))
        #expect(bad.end >= bad.start)
        let r = sched.schedule(items: [item(30, dueDay: 25)], commitments: [bad], now: now)
        #expect(r.sessions.count == 1)
    }

    @Test("a zero-minute item is clamped rather than looping")
    func zeroDuration() {
        let it = ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: 0,
                              minutes: 0, deadline: at(25, 23))
        #expect(it.duration > 0)
        let r = sched.schedule(items: [it], now: now)
        #expect(r.sessions.count == 1)
    }

    @Test("an absurd deadline terminates instead of hanging")
    func farFutureDeadline() {
        let it = ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: 0,
                              minutes: 60, deadline: at(20, 9).addingTimeInterval(86_400 * 3650))
        let r = sched.schedule(items: [it], now: now)
        #expect(r.sessions.count == 1)
    }

    @Test("an item longer than any single day is reported, not wedged in")
    func itemLongerThanCapacity() {
        let r = sched.schedule(items: [item(600, dueDay: 30)], now: now)
        #expect(r.sessions.isEmpty)
        #expect(r.unplaceable.count == 1)
    }

    @Test("a large plan completes quickly")
    func performance() {
        let items = (0..<400).map { item(30, dueDay: 90, ordinal: $0) }
        let started = Date()
        let r = sched.schedule(items: items, now: now)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2.0, "took \(elapsed)s")
        #expect(r.sessions.count + r.unplaceable.count == 400)
    }
}

/// The behaviour the whole product rests on: when a student misses a session,
/// Albus finds it a new home rather than leaving it in the past.
@Suite("Missed work is re-placed")
struct MissedWorkTests {

    /// Yesterday, entirely in the past, and marked missed — which is what the
    /// app does to a block whose window passed with the step still undone.
    private func missedSession(_ item: ScheduleItem,
                               startHour: Int = 16, minutes: Int = 60) -> PlannedSession {
        PlannedSession(
            itemID: item.id, assignmentID: item.assignmentID,
            start: at(19, startHour),
            end: at(19, startHour).addingTimeInterval(TimeInterval(minutes * 60)),
            state: .missed
        )
    }

    /// A past block nobody marked is left where it is: we do not know whether
    /// that work happened, and rewriting it would erase a day the student may
    /// have worked through.
    @Test("an unmarked past block is not disturbed")
    func unmarkedPastIsPinned() {
        let work = item(60, dueDay: 23)
        let stale = PlannedSession(
            itemID: work.id, assignmentID: work.assignmentID,
            start: at(19, 16), end: at(19, 17), state: .scheduled
        )
        let r = sched.schedule(items: [work], existing: [stale], now: now)
        #expect(r.movedCount == 0)
    }

    @Test("a session whose window has passed is moved into the future")
    func missedIsMoved() {
        let work = item(60, dueDay: 23)
        let missed = missedSession(work)

        let r = sched.schedule(items: [work], existing: [missed], now: now)

        #expect(r.sessions.count == 1)
        let placed = try! #require(r.sessions.first)
        // The whole point: it now sits ahead of the clock, not behind it.
        #expect(placed.start >= now)
        // And it is the same session moved, not a duplicate alongside the old.
        #expect(placed.itemID == work.id)
    }

    @Test("missed work does not keep blocking the slot it never used")
    func missedFreesItsSlot() {
        // Two steps, one missed. The missed block sat at 16:00-17:00 yesterday;
        // that time must not count as occupied today.
        let first = item(60, dueDay: 23, ordinal: 0)
        let second = item(60, dueDay: 23, ordinal: 1)
        let missed = missedSession(first)

        let r = sched.schedule(items: [first, second], existing: [missed], now: now)

        #expect(r.sessions.count == 2)
        // Nothing may overlap anything else.
        let sorted = r.sessions.sorted { $0.start < $1.start }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(a.end <= b.start)
        }
    }

    @Test("a block in progress right now is left alone")
    func inProgressIsPinned() {
        let work = item(60, dueDay: 23)
        // Started an hour ago, still running: 08:30 to 09:30, now is 09:00.
        let running = PlannedSession(
            itemID: work.id, assignmentID: work.assignmentID,
            start: at(20, 8, 30), end: at(20, 9, 30), state: .scheduled
        )

        let r = sched.schedule(items: [work], existing: [running], now: now)

        // Untouched — the student is sitting in front of it.
        #expect(r.sessions.contains { $0.id == running.id && $0.start == running.start })
        #expect(r.movedCount == 0)
    }

    @Test("completed work stays exactly where it happened")
    func completedIsPinned() {
        let work = item(60, dueDay: 23)
        let done = PlannedSession(
            itemID: work.id, assignmentID: work.assignmentID,
            start: at(19, 16), end: at(19, 17), state: .completed
        )

        // The item is no longer pending once its session is complete.
        let r = sched.schedule(items: [], existing: [done], now: now)

        #expect(r.sessions.contains { $0.id == done.id && $0.start == done.start })
    }
}
