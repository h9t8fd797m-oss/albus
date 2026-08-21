import Testing
import Foundation
@testable import AlbusCore

/// Property-based sweep over the scheduler.
///
/// The hand-written tests check cases I thought of. These check invariants
/// against inputs I did not — the ones that actually break schedulers in the
/// wild: zero-length windows, deadlines in the past, commitments that swallow
/// every available hour, hundreds of items competing for one evening.
///
/// Seeded so a failure is reproducible rather than a story about a flake.
private struct Rand: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

private let cal = Scheduler.defaultCalendar
private let base = cal.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 9))!

@Suite("Fuzz — invariants under arbitrary input")
struct FuzzTests {

    @Test("invariants hold across 300 randomised scenarios")
    func invariants() {
        let sched = Scheduler()

        for seed in 0..<300 {
            var rng = Rand(seed: UInt64(seed) &+ 1)

            let itemCount = Int.random(in: 0...40, using: &rng)
            let items = (0..<itemCount).map { i in
                ScheduleItem(
                    id: UUID(),
                    assignmentID: UUID(),
                    ordinal: i,
                    // includes 0 and absurdly large
                    minutes: [0, 1, 15, 45, 90, 240, 900].randomElement(using: &rng)!,
                    // includes deadlines in the past
                    deadline: base.addingTimeInterval(
                        Double(Int.random(in: -5...40, using: &rng)) * 86_400)
                )
            }

            let commitmentCount = Int.random(in: 0...8, using: &rng)
            let commitments = (0..<commitmentCount).map { _ -> FixedCommitment in
                let start = base.addingTimeInterval(
                    Double(Int.random(in: 0...(40 * 24), using: &rng)) * 3600)
                // includes inverted and zero-length
                let hours = Double(Int.random(in: -3...10, using: &rng))
                return FixedCommitment(start: start, end: start.addingTimeInterval(hours * 3600))
            }

            let startHour = Int.random(in: 0...23, using: &rng)
            let availability = Availability(
                windowStartHour: startHour,
                windowEndHour: Int.random(in: 0...24, using: &rng),
                dailyCapacityMinutes: [0, 30, 150, 600, 1440].randomElement(using: &rng)!,
                excludedWeekdays: Set((1...7).filter { _ in Bool.random(using: &rng) })
            )

            let result = sched.schedule(items: items, commitments: commitments,
                                        availability: availability, now: base)

            let context = "seed \(seed)"

            // 1. Nothing vanishes: every item is placed or reported.
            let accountedFor = Set(result.sessions.map(\.itemID))
                .union(result.unplaceable.map(\.id))
            #expect(accountedFor.count == items.count, "work went missing — \(context)")

            // 2. Nothing is scheduled into the past.
            for s in result.sessions {
                #expect(s.start >= base, "scheduled in the past — \(context)")
            }

            // 3. Sessions never overlap each other.
            let sorted = result.sessions.sorted { $0.start < $1.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                #expect(a.end <= b.start, "overlapping sessions — \(context)")
            }

            // 4. Sessions never overlap a fixed commitment.
            for s in result.sessions {
                for c in commitments where c.end > c.start {
                    #expect(!(s.start < c.end && s.end > c.start),
                            "ran through a commitment — \(context)")
                }
            }

            // 5. Nothing is scheduled past its own deadline.
            let deadlines = Dictionary(items.map { ($0.id, $0.deadline) },
                                       uniquingKeysWith: { a, _ in a })
            for s in result.sessions {
                if let due = deadlines[s.itemID] {
                    #expect(s.end <= due, "scheduled past the deadline — \(context)")
                }
            }

            // 6. Daily capacity is never exceeded.
            if availability.dailyCapacityMinutes > 0 {
                var perDay: [Date: TimeInterval] = [:]
                for s in result.sessions {
                    perDay[cal.startOfDay(for: s.start), default: 0] += s.duration
                }
                for (_, used) in perDay {
                    #expect(used <= Double(availability.dailyCapacityMinutes) * 60 + 1,
                            "exceeded daily capacity — \(context)")
                }
            }

            // 7. Excluded days stay empty.
            for s in result.sessions {
                #expect(!availability.excludedWeekdays.contains(cal.component(.weekday, from: s.start)),
                        "scheduled on an excluded day — \(context)")
            }

            // 8. Every session has positive duration.
            for s in result.sessions {
                #expect(s.end > s.start, "zero-length session — \(context)")
            }
        }
    }

    @Test("re-scheduling repeatedly converges instead of churning")
    func repeatedRunsAreStable() {
        let sched = Scheduler()
        let items = (0..<15).map {
            ScheduleItem(id: UUID(), assignmentID: UUID(), ordinal: $0,
                         minutes: 45, deadline: base.addingTimeInterval(20 * 86_400))
        }
        var existing = sched.schedule(items: items, now: base).sessions

        // Nothing about the world changed, so nothing should move.
        for run in 0..<5 {
            let r = sched.schedule(items: items, existing: existing, now: base)
            #expect(r.movedCount == 0, "run \(run) moved \(r.movedCount) sessions for no reason")
            existing = r.sessions
        }
    }
}
