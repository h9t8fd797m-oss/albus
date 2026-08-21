import Foundation

/// One finished piece of work. Mirrors the `completion_logs` payload exactly
/// and, like it, carries **no free text** — task type and durations only, never
/// what the student was actually working on.
public struct CompletionLog: Sendable, Equatable {
    public let subjectCode: String?
    public let taskType: String
    public let estimatedMinutes: Int
    public let actualMinutes: Int
    public let scheduledHour: Int?
    public let completed: Bool
    /// `true` only when a real timer produced the number. Inferred completions
    /// are weaker evidence and are weighted down.
    public let highConfidence: Bool
    public let at: Date

    public init(subjectCode: String?, taskType: String, estimatedMinutes: Int,
                actualMinutes: Int, scheduledHour: Int? = nil, completed: Bool = true,
                highConfidence: Bool = false, at: Date) {
        self.subjectCode = subjectCode
        self.taskType = taskType
        self.estimatedMinutes = max(1, estimatedMinutes)
        self.actualMinutes = max(1, actualMinutes)
        self.scheduledHour = scheduledHour
        self.completed = completed
        self.highConfidence = highConfidence
        self.at = at
    }

    var ratio: Double { Double(actualMinutes) / Double(estimatedMinutes) }
}

/// Learns how long *this* student actually takes, from their own history, on
/// their own device.
///
/// No machine-learning library is involved, deliberately. A student produces
/// maybe fifty observations in a month, and almost nothing in scikit-learn is
/// well-behaved at n=50 — a model that overfits someone's first fortnight feels
/// worse than a sensible default. What works at that size is hierarchical
/// shrinkage, which is about forty lines and degrades gracefully to the prior
/// instead of inventing structure that is not there.
///
/// Levels, each shrunk toward the next:
///     (subject, task type)  →  subject  →  this user  →  population
public struct Estimator: Sendable {

    /// Pseudo-observations of the prior. Higher means slower to trust new data.
    /// At k = 5, a single observation moves the estimate about a sixth of the
    /// way, which is roughly the right amount of scepticism.
    private let k: Double
    /// Nothing outside this range is a real signal; it is a data bug.
    private let clamp: ClosedRange<Double>
    /// Recent behaviour counts for more — a student in October is not the one
    /// who signed up in August.
    private let halfLifeDays: Double

    public init(k: Double = 5, clamp: ClosedRange<Double> = 0.5...3.0,
                halfLifeDays: Double = 30) {
        self.k = max(0.1, k)
        self.clamp = clamp
        self.halfLifeDays = max(1, halfLifeDays)
    }

    /// Adjusted estimate for a piece of work, plus how much to trust it.
    public func estimate(baseMinutes: Int, subjectCode: String?, taskType: String,
                         logs: [CompletionLog], populationPrior: Double = 1.0,
                         now: Date) -> (minutes: Int, confidence: Double) {

        // Each level uses only the observations that belong to it, and nothing
        // finer. Letting the same log appear at every level compounds its
        // influence: a single 3x observation shrunk three times against k = 5
        // lands at 1.84x rather than the 1.33x one data point is worth.
        let cell = logs.filter { $0.subjectCode == subjectCode && $0.taskType == taskType }
        let subjectOnly = logs.filter { $0.subjectCode == subjectCode && $0.taskType != taskType }
        let otherSubjects = logs.filter { $0.subjectCode != subjectCode }

        let userRatio    = shrink(otherSubjects, toward: populationPrior, now: now)
        let subjectRatio = shrink(subjectOnly,   toward: userRatio,       now: now)
        let cellRatio    = shrink(cell,          toward: subjectRatio,    now: now)

        let ratio = min(max(cellRatio, clamp.lowerBound), clamp.upperBound)
        let minutes = Int((Double(max(1, baseMinutes)) * ratio).rounded())

        // Confidence saturates around ten relevant observations.
        let confidence = min(1.0, Double(cell.count) / 10.0)
        return (max(1, minutes), confidence)
    }

    /// Weighted median shrunk toward a prior.
    ///
    /// Median rather than mean on purpose: one session where the student left a
    /// timer running over dinner would drag a mean badly, and that is a common
    /// real event rather than a hypothetical.
    func shrink(_ sample: [CompletionLog], toward prior: Double, now: Date) -> Double {
        guard !sample.isEmpty else { return prior }

        let weighted = sample.map { log -> (ratio: Double, weight: Double) in
            let ageDays = max(0, now.timeIntervalSince(log.at) / 86_400)
            let recency = pow(0.5, ageDays / halfLifeDays)
            let evidence = log.highConfidence ? 1.0 : 0.5
            return (log.ratio, recency * evidence)
        }

        let n = weighted.reduce(0) { $0 + $1.weight }
        guard n > 0, let median = weightedMedian(weighted) else { return prior }

        return (n * median + k * prior) / (n + k)
    }

    private func weightedMedian(_ values: [(ratio: Double, weight: Double)]) -> Double? {
        let sorted = values.sorted { $0.ratio < $1.ratio }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }

        var cumulative = 0.0
        for entry in sorted {
            cumulative += entry.weight
            if cumulative >= total / 2 { return entry.ratio }
        }
        return sorted.last?.ratio
    }

    /// How reliably the student finishes what they start at a given hour.
    ///
    /// Laplace-smoothed so a single data point cannot produce 0% or 100%.
    /// This is a fact about their history, not a prediction, which is exactly
    /// why it does not need a model.
    public func completionRate(hour: Int, logs: [CompletionLog]) -> Double {
        let at = logs.filter { $0.scheduledHour == hour }
        return Double(at.filter(\.completed).count + 1) / Double(at.count + 2)
    }

    /// Typical minutes between a session's scheduled start and its real one.
    /// If it is reliably positive, stop fighting it and schedule accordingly.
    public func typicalStartDelay(minutesLate: [Int]) -> Int {
        guard !minutesLate.isEmpty else { return 0 }
        let sorted = minutesLate.sorted()
        return sorted[sorted.count / 2]
    }
}
