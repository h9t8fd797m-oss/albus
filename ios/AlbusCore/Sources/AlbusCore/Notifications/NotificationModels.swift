import Foundation

/// Everything Albus can say when the app is closed.
///
/// Flat rather than nested with associated values, because the raw string is
/// the notification's identifier prefix and `CaseIterable` is what lets the
/// corpus tests prove every reachable kind has something to say.
public enum NotificationKind: String, Sendable, Hashable, CaseIterable {
    /// What today looks like, once, in the morning.
    case morningBrief
    /// The first block of the day is starting.
    case windowNudge
    case deadline72
    case deadline24
    case deadline03
    /// Due today and not finished.
    case handInToday
    /// The scheduler stopped being able to place this work before its deadline.
    case planStoppedFitting
    /// The deadline has passed and the work is not done.
    case overdue
    case dormantSoft
    case dormantFinal
    /// "These clearly are not working." The last one before going quiet.
    case backOff
    /// A soft note about the week's measured focus. Nothing to lose.
    case momentum

    /// Lower goes first when the day is full, and survives the 64-slot budget.
    ///
    /// Tier 1 is the set that still fires while reminders are paused: they are
    /// warnings about real consequences rather than nudges, and the student
    /// ignoring Albus is not a reason to let them miss a hand-in.
    public var tier: Int {
        switch self {
        case .overdue, .handInToday, .planStoppedFitting: 1
        case .deadline03, .deadline24, .deadline72: 2
        case .morningBrief, .momentum: 3
        case .windowNudge: 4
        case .dormantSoft, .dormantFinal, .backOff: 5
        }
    }

    /// Whether this kind may use the chaotic register.
    ///
    /// **The line is "can the student still do something about it".** A joke
    /// about a deadline you can still hit is funny and is the whole point of
    /// the voice. A joke about one you have already missed is punching at
    /// someone who is having a bad day, and no setting should be able to
    /// produce it — which is why this is a property of the kind rather than a
    /// note asking authors to be careful.
    public var allowsChaos: Bool {
        self != .overdue
    }

    /// Kinds that compete for the same moment in the day.
    ///
    /// Everything anchored to the morning brief hour shares one slot, so a
    /// hand-in warning replaces the brief rather than arriving beside it and
    /// spending two thirds of the daily allowance on one moment.
    public var slot: Slot {
        switch self {
        case .morningBrief, .handInToday, .overdue,
             .dormantSoft, .dormantFinal, .backOff, .momentum: .brief
        case .windowNudge: .nudge
        case .deadline72, .deadline24, .deadline03, .planStoppedFitting: .free
        }
    }

    public enum Slot: Sendable, Hashable { case brief, nudge, free }
}

/// How loud Albus is allowed to be, and in what voice.
public struct NotificationSettings: Sendable, Equatable {
    public var enabled: Bool
    /// Drops the chaotic register everywhere. The escape hatch for a student
    /// who wants a planner rather than a personality.
    public var seriousMode: Bool
    public var briefHour: Int
    public var briefMinute: Int
    public var nudgeEnabled: Bool
    public var warnAt72h: Bool
    public var warnAt24h: Bool
    public var warnAt3h: Bool
    public var quietStartHour: Int
    public var quietEndHour: Int
    public var maxPerDay: Int

    public init(enabled: Bool = true, seriousMode: Bool = false,
                briefHour: Int = 7, briefMinute: Int = 30,
                nudgeEnabled: Bool = true,
                warnAt72h: Bool = false, warnAt24h: Bool = true, warnAt3h: Bool = true,
                quietStartHour: Int = 22, quietEndHour: Int = 7,
                maxPerDay: Int = 2) {
        self.enabled = enabled
        self.seriousMode = seriousMode
        self.briefHour = max(0, min(23, briefHour))
        self.briefMinute = max(0, min(59, briefMinute))
        self.nudgeEnabled = nudgeEnabled
        self.warnAt72h = warnAt72h
        self.warnAt24h = warnAt24h
        self.warnAt3h = warnAt3h
        self.quietStartHour = max(0, min(23, quietStartHour))
        self.quietEndHour = max(0, min(23, quietEndHour))
        self.maxPerDay = max(1, min(8, maxPerDay))
    }

    public static let `default` = NotificationSettings()
}

/// One assignment, reduced to what Albus can talk about.
///
/// A value type on purpose: the planner must never touch SwiftData, both
/// because reading a relationship off the main actor is undefined and because
/// keeping it pure is what allows the whole policy layer to be tested with no
/// simulator at all.
public struct NotificationAssignment: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let deadline: Date
    public let isComplete: Bool
    public let remainingSteps: Int
    public let remainingMinutes: Int
    /// The step the student should do next, for a line that names one thing.
    public let nextStepTitle: String?
    /// Whether any of this assignment's work could not be placed at all.
    public let hasUnplaceable: Bool

    public init(id: UUID, title: String, deadline: Date, isComplete: Bool,
                remainingSteps: Int, remainingMinutes: Int,
                nextStepTitle: String? = nil, hasUnplaceable: Bool = false) {
        self.id = id
        self.title = title
        self.deadline = deadline
        self.isComplete = isComplete
        self.remainingSteps = max(0, remainingSteps)
        self.remainingMinutes = max(0, remainingMinutes)
        self.nextStepTitle = nextStepTitle
        self.hasUnplaceable = hasUnplaceable
    }
}

/// A block the scheduler placed.
public struct NotificationBlock: Sendable, Equatable {
    public let assignmentID: UUID
    public let assignmentTitle: String
    public let stepTitle: String
    public let start: Date
    public let minutes: Int

    public init(assignmentID: UUID, assignmentTitle: String, stepTitle: String,
                start: Date, minutes: Int) {
        self.assignmentID = assignmentID
        self.assignmentTitle = assignmentTitle
        self.stepTitle = stepTitle
        self.start = start
        self.minutes = max(0, minutes)
    }
}

/// Everything the planner is allowed to know.
public struct NotificationContext: Sendable {
    public let assignments: [NotificationAssignment]
    public let blocks: [NotificationBlock]
    public let workload: WorkloadState
    public let availability: Availability
    public let settings: NotificationSettings
    /// Measured focus over the last seven days, for the momentum line.
    public let weeklyFocusedMinutes: Int
    public let previousWeeklyFocusedMinutes: Int
    public let lastOpened: Date
    /// How many steps the scheduler could not place at all.
    public let unplaceableCount: Int
    /// Stable hash of the currently unplaceable step ids.
    public let unplaceableSignature: String
    /// The same, as of the last rebuild. A *transition* is the alarm; a
    /// standing state is not, or one oversized step alarms forever.
    public let previousUnplaceableSignature: String
    /// Set while backed off. Tier 1 still fires.
    public let pausedUntil: Date?
    public let now: Date

    public init(assignments: [NotificationAssignment] = [],
                blocks: [NotificationBlock] = [],
                workload: WorkloadState = .calm,
                availability: Availability = .default,
                settings: NotificationSettings = .default,
                weeklyFocusedMinutes: Int = 0,
                previousWeeklyFocusedMinutes: Int = 0,
                lastOpened: Date = .distantPast,
                unplaceableCount: Int = 0,
                unplaceableSignature: String = "",
                previousUnplaceableSignature: String = "",
                pausedUntil: Date? = nil,
                now: Date) {
        self.assignments = assignments
        self.blocks = blocks
        self.workload = workload
        self.availability = availability
        self.settings = settings
        self.weeklyFocusedMinutes = max(0, weeklyFocusedMinutes)
        self.previousWeeklyFocusedMinutes = max(0, previousWeeklyFocusedMinutes)
        self.lastOpened = lastOpened
        self.unplaceableCount = max(0, unplaceableCount)
        self.unplaceableSignature = unplaceableSignature
        self.previousUnplaceableSignature = previousUnplaceableSignature
        self.pausedUntil = pausedUntil
        self.now = now
    }
}

/// One notification, fully rendered, ready to become a `UNNotificationRequest`.
public struct PlannedNotification: Sendable, Equatable, Identifiable {
    /// Stable and content-free: re-adding with the same id replaces in place,
    /// which is the cheapest update iOS offers.
    public let id: String
    public let kind: NotificationKind
    public let fireDate: Date
    public let title: String
    public let body: String
    /// Groups a stack per assignment in Notification Centre.
    public let threadID: String?
    /// Which cactus to attach.
    public let mood: WorkloadState
    /// The template that produced the body, so it can be suppressed next time.
    public let templateID: String
    /// Changes whenever the rendered content or timing changes. The diff adds
    /// only what this says is different.
    public var fingerprint: String {
        StableHash.string("\(fireDate.timeIntervalSince1970)|\(title)|\(body)")
    }

    public init(id: String, kind: NotificationKind, fireDate: Date,
                title: String, body: String, threadID: String? = nil,
                mood: WorkloadState = .calm, templateID: String = "") {
        self.id = id
        self.kind = kind
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.threadID = threadID
        self.mood = mood
        self.templateID = templateID
    }
}
