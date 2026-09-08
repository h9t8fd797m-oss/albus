import Foundation

/// A deadline-scoped view of the existing solver result, not another capacity estimate.
public struct WeekFit: Sendable, Equatable {
    public let workload: WorkloadState
    public let items: [ScheduleItem]

    public var assignmentIDs: Set<UUID> { Set(items.map(\.assignmentID)) }
    public var minutesNeedingTime: Int {
        Int(ceil(items.reduce(0) { $0 + $1.duration } / 60))
    }

    public init?(unplaceable: [ScheduleItem], workload: WorkloadState,
                 now: Date, calendar: Calendar = .current) {
        guard let end = calendar.date(byAdding: .day, value: 7, to: now) else { return nil }
        // Overdue work still needs a decision. Future failures must not make
        // this week's finite-hours answer sound worse than it is.
        let relevant = unplaceable.filter { $0.deadline <= end }
            .sorted {
                if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
                if $0.assignmentID != $1.assignmentID {
                    return $0.assignmentID.uuidString < $1.assignmentID.uuidString
                }
                return $0.ordinal < $1.ordinal
            }
        guard !relevant.isEmpty else { return nil }
        self.workload = workload
        self.items = relevant
    }
}
