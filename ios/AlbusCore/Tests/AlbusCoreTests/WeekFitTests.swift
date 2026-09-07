import Foundation
import Testing
@testable import AlbusCore

@Suite("Week fit")
struct WeekFitTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A full but placeable week is quiet for every workload state")
    func quiet() {
        for state: WorkloadState in [.calm, .busy, .cooked] {
            #expect(WeekFit(unplaceable: [], workload: state, now: now) == nil)
        }
    }

    @Test("One solver exposes competition across subjects")
    func competingAssignments() {
        let due = now.addingTimeInterval(3600)
        let items = (0..<6).map { _ in
            ScheduleItem(id: UUID(), assignmentID: UUID(), ordinal: 0,
                         minutes: 60, deadline: due)
        }
        let result = Scheduler().schedule(items: items,
            availability: Availability(windowStartHour: 0, windowEndHour: 24,
                                       dailyCapacityMinutes: 60), now: now)
        let fit = WeekFit(unplaceable: result.unplaceable, workload: result.workload, now: now)
        #expect(fit?.workload == .cooked)
        #expect(fit?.items.count == 5)
        #expect(fit?.assignmentIDs.count == 5)
        #expect(fit?.minutesNeedingTime == 300)
    }

    @Test("Includes overdue work, counts assignments once and excludes later deadlines")
    func scope() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let boundary = calendar.date(byAdding: .day, value: 7, to: now)!
        let assignment = UUID()
        let items = [
            ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: 0,
                         minutes: 20, deadline: now.addingTimeInterval(-1)),
            ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: 1,
                         minutes: 30, deadline: boundary),
            ScheduleItem(id: UUID(), assignmentID: UUID(), ordinal: 0,
                         minutes: 90, deadline: boundary.addingTimeInterval(1))
        ]
        let fit = WeekFit(unplaceable: items, workload: .cooked, now: now, calendar: calendar)
        #expect(fit?.items.count == 2)
        #expect(fit?.assignmentIDs == [assignment])
        #expect(fit?.minutesNeedingTime == 50)
        #expect(WeekFit(unplaceable: [items[2]], workload: .cooked,
                        now: now, calendar: calendar) == nil)
    }

    @Test("Seven local days retain the boundary across daylight saving")
    func daylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        let item = ScheduleItem(id: UUID(), assignmentID: UUID(), ordinal: 0, minutes: 30, deadline: end)
        #expect(WeekFit(unplaceable: [item], workload: .cooked, now: start, calendar: calendar) != nil)
    }
}
