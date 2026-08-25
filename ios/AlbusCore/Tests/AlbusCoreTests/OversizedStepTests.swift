import Foundation
import Testing
@testable import AlbusCore

/// Why a step may never be longer than the student's daily capacity.
///
/// This is the scheduler behaviour that `sessionCeiling` in the edge function
/// exists to respect: `findSlot` skips any day whose remaining capacity is
/// below the step's length, and a step that fits nowhere is not shortened or
/// split — it is dropped into `unplaceable` and never appears on the calendar.
///
/// The planner used to be allowed 480-minute steps. With a three-hour study
/// day that is a step which can never be scheduled on any of sixty available
/// days, and nothing in the app said so.
@Suite("Oversized steps")
struct OversizedStepTests {

    @Test("a step longer than the daily capacity cannot be placed at all")
    func oversizedStepIsUnplaceable() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let deadline = Calendar.current.date(byAdding: .day, value: 60, to: now)!
        let assignment = UUID()

        // 8 hours — what MAX_STEP_MINUTES currently permits.
        let item = ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: 0,
                                minutes: 480, deadline: deadline)

        let result = Scheduler().schedule(
            items: [item], existing: [], commitments: [],
            availability: Availability(dailyCapacityMinutes: 180), now: now)

        print("── 480-minute step, 180-min/day capacity, 60 days available")
        print("   placed: \(result.sessions.count)  unplaceable: \(result.unplaceable.count)")
        #expect(result.unplaceable.count == 1,
                "expected the oversized step to be unplaceable")
        #expect(result.sessions.isEmpty)
    }

    @Test("the same work as sittable steps schedules fine")
    func sameWorkSplitIsPlaceable() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let deadline = Calendar.current.date(byAdding: .day, value: 60, to: now)!
        let assignment = UUID()

        // 480 minutes as 8 x 60, the same total work.
        let items = (0..<8).map {
            ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: $0,
                         minutes: 60, deadline: deadline)
        }
        let result = Scheduler().schedule(
            items: items, existing: [], commitments: [],
            availability: Availability(dailyCapacityMinutes: 180), now: now)

        print("── same 480 minutes as 8 x 60-minute steps")
        print("   placed: \(result.sessions.count)  unplaceable: \(result.unplaceable.count)")
        #expect(result.unplaceable.isEmpty)
        #expect(result.sessions.count == 8)
    }
}

/// An impossible workload must be reported, not silently dropped.
@Suite("Impossible workloads")
struct ImpossibleWorkloadTests {

    @Test("work that cannot fit before the deadline is reported as unplaceable")
    func overloadedDeadlineIsReported() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        // Twenty hours of sittable steps, due tomorrow, three hours a day.
        let deadline = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let assignment = UUID()
        let items = (0..<16).map {
            ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: $0,
                         minutes: 75, deadline: deadline)
        }
        let result = Scheduler().schedule(
            items: items, existing: [], commitments: [],
            availability: Availability(dailyCapacityMinutes: 180), now: now)

        print("── 16 x 75min due tomorrow, 180min/day")
        print("   placed: \(result.sessions.count)  unplaceable: \(result.unplaceable.count)")
        #expect(!result.unplaceable.isEmpty,
                "an impossible workload reported nothing unplaceable")
        // The app reads this now; before, it was computed and discarded, so a
        // plan that did not fit looked exactly like one that did.
        #expect(result.sessions.count < items.count)
    }
}
