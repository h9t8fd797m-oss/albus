import Testing
import Foundation
@testable import AlbusCore

private let cal = Scheduler.defaultCalendar
private let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 9))!

private func log(est: Int, act: Int, subject: String? = "HIST", type: String = "essay",
                 daysAgo: Double = 1, hour: Int? = nil, completed: Bool = true,
                 confident: Bool = true) -> CompletionLog {
    CompletionLog(subjectCode: subject, taskType: type, estimatedMinutes: est,
                  actualMinutes: act, scheduledHour: hour, completed: completed,
                  highConfidence: confident, at: now.addingTimeInterval(-daysAgo * 86_400))
}

private let est = Estimator()

@Suite("Estimator")
struct EstimatorTests {

    @Test("with no history it returns the base estimate")
    func noHistory() {
        let r = est.estimate(baseMinutes: 60, subjectCode: "HIST", taskType: "essay",
                             logs: [], now: now)
        #expect(r.minutes == 60)
        #expect(r.confidence == 0)
    }

    @Test("a consistent overrunner gets longer estimates")
    func learnsOverrun() {
        // Consistently takes 1.5x as long.
        let logs = (0..<12).map { _ in log(est: 60, act: 90) }
        let r = est.estimate(baseMinutes: 60, subjectCode: "HIST", taskType: "essay",
                             logs: logs, now: now)
        #expect(r.minutes > 70, "expected an upward adjustment, got \(r.minutes)")
        #expect(r.confidence > 0.9)
    }

    @Test("one observation barely moves the estimate")
    func singleObservationIsWeak() {
        let r = est.estimate(baseMinutes: 60, subjectCode: "HIST", taskType: "essay",
                             logs: [log(est: 60, act: 180)], now: now)
        // 3x on one data point must not produce a 3x estimate.
        #expect(r.minutes < 90, "one outlier moved the estimate to \(r.minutes)")
        #expect(r.confidence < 0.2)
    }

    @Test("a runaway timer does not wreck the estimate")
    func medianResistsOutlier() {
        var logs = (0..<11).map { _ in log(est: 60, act: 60) }
        logs.append(log(est: 60, act: 2000))   // left the timer running over dinner
        let r = est.estimate(baseMinutes: 60, subjectCode: "HIST", taskType: "essay",
                             logs: logs, now: now)
        #expect(r.minutes <= 75, "outlier dragged the estimate to \(r.minutes)")
    }

    @Test("the ratio is clamped against absurd data")
    func clamped() {
        let logs = (0..<40).map { _ in log(est: 1, act: 1440) }
        let r = est.estimate(baseMinutes: 60, subjectCode: "HIST", taskType: "essay",
                             logs: logs, now: now)
        #expect(r.minutes <= 180, "clamp did not hold: \(r.minutes)")
    }

    @Test("recent behaviour outweighs old behaviour")
    func recencyWeighted() {
        let old = (0..<20).map { _ in log(est: 60, act: 120, daysAgo: 300) }
        let recent = (0..<20).map { _ in log(est: 60, act: 60, daysAgo: 1) }
        let r = est.estimate(baseMinutes: 60, subjectCode: "HIST", taskType: "essay",
                             logs: old + recent, now: now)
        #expect(r.minutes < 80, "stale data dominated: \(r.minutes)")
    }

    @Test("a different subject falls back rather than borrowing blindly")
    func subjectSpecific() {
        let histLogs = (0..<15).map { _ in log(est: 60, act: 120, subject: "HIST") }
        let r = est.estimate(baseMinutes: 60, subjectCode: "MATH", taskType: "problem_set",
                             logs: histLogs, now: now)
        // Some carry-over from the user's global tendency is correct; full
        // adoption of an unrelated subject's ratio is not.
        #expect(r.minutes < 120)
        #expect(r.confidence == 0)
    }

    @Test("timer-backed data counts for more than inferred data")
    func confidenceWeighting() {
        let inferred = (0..<10).map { _ in log(est: 60, act: 120, confident: false) }
        let timed = (0..<10).map { _ in log(est: 60, act: 120, confident: true) }
        let a = est.estimate(baseMinutes: 60, subjectCode: "HIST", taskType: "essay",
                             logs: inferred, now: now).minutes
        let b = est.estimate(baseMinutes: 60, subjectCode: "HIST", taskType: "essay",
                             logs: timed, now: now).minutes
        #expect(b >= a, "timer-backed evidence should move the estimate at least as much")
    }

    @Test("completion rate is smoothed against tiny samples")
    func completionRateSmoothed() {
        // A single failure at 23:00 must not read as a flat 0%.
        let rate = est.completionRate(hour: 23, logs: [log(est: 60, act: 60, hour: 23, completed: false)])
        #expect(rate > 0 && rate < 0.5)
        // No data at all sits at the neutral midpoint.
        #expect(est.completionRate(hour: 7, logs: []) == 0.5)
    }

    @Test("start delay is the median, not the mean")
    func startDelayMedian() {
        #expect(est.typicalStartDelay(minutesLate: [5, 10, 15, 20, 600]) == 15)
        #expect(est.typicalStartDelay(minutesLate: []) == 0)
    }
}
