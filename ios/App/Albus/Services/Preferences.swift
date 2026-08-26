import Foundation
import Observation
import AlbusCore

/// What the student told us about themselves, and what Albus plans with.
///
/// UserDefaults rather than SwiftData: these are a handful of scalars read on
/// every schedule, they are device settings rather than user content, and
/// putting them in the store would mean a migration every time one is added.
@Observable
@MainActor
final class Preferences {

    enum Program: String, CaseIterable, Identifiable, Sendable {
        case ib = "IB"
        case aLevel = "A-Level"
        case ap = "AP"
        case university = "University"
        case other = "Other"
        var id: String { rawValue }

        /// The qualification in the bundled curriculum data, where there is one.
        /// This is the join between "what the student says they do" and "what
        /// Albus knows about how that is assessed".
        var qualification: CurriculumSubject.Qualification? {
            switch self {
            case .ib: .ibDP
            case .aLevel: .aLevel
            case .ap: .ap
            case .university, .other: nil
            }
        }

        /// The `curricula.code` this maps to. Kept next to the cases so adding a
        /// programme cannot silently produce a foreign key the server rejects.
        /// Exhaustive on purpose — no default — for the same reason.
        ///
        /// A-level carries the board, because boards genuinely assess the same
        /// subject differently and one code for all of them would be a lie the
        /// planner would then act on. Every other programme has a single
        /// authority and ignores the argument.
        func curriculumCode(board: String?) -> String {
            switch self {
            case .ib: "IB_DP"
            case .aLevel: "A_LEVEL_\(board ?? Preferences.defaultExamBoard)"
            case .ap: "AP"
            case .university, .other: "GENERIC"
            }
        }
    }

    /// The three buckets onboarding offers, mapped to real capacity.
    enum StudyLoad: String, CaseIterable, Identifiable, Sendable {
        case light, standard, heavy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .light: "Under 2h"
            case .standard: "2 to 4h"
            case .heavy: "4h plus"
            }
        }

        /// The middle of each bucket, in minutes. A student who says "2 to 4"
        /// is told three hours of work fits, not four — a plan that is always
        /// slightly achievable beats one that is occasionally impossible.
        var dailyCapacityMinutes: Int {
            switch self {
            case .light: 90
            case .standard: 180
            case .heavy: 270
            }
        }
    }

    private enum Key {
        static let name = "albus.profile.name"
        static let program = "albus.profile.program"
        static let board = "albus.profile.board"
        static let load = "albus.profile.load"
        static let onboarded = "albus.profile.onboarded"
        static let windowStart = "albus.profile.windowStart"
        static let windowEnd = "albus.profile.windowEnd"
        static let daysOff = "albus.profile.daysOff"
    }

    /// Where the corpus currently starts. Not a favourite — it is the one board
    /// whose specifications have actually been read and verified.
    ///
    /// `nonisolated` because `Program.curriculumCode(board:)` is a plain method
    /// on a `Sendable` enum and has no business hopping to the main actor to
    /// read a constant string.
    nonisolated static let defaultExamBoard = "AQA"


    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        name = defaults.string(forKey: Key.name) ?? ""
        program = Program(rawValue: defaults.string(forKey: Key.program) ?? "") ?? .ib
        examBoard = defaults.string(forKey: Key.board) ?? Self.defaultExamBoard
        load = StudyLoad(rawValue: defaults.string(forKey: Key.load) ?? "") ?? .standard
        hasOnboarded = defaults.bool(forKey: Key.onboarded)

        // `object(forKey:)` rather than `integer(forKey:)`: an unset integer key
        // reads back as 0, which is a legitimate hour and would silently move
        // every existing student's study window to midnight.
        windowStartHour = defaults.object(forKey: Key.windowStart) as? Int
            ?? Availability.default.windowStartHour
        windowEndHour = defaults.object(forKey: Key.windowEnd) as? Int
            ?? Availability.default.windowEndHour
        daysOff = Set(defaults.array(forKey: Key.daysOff) as? [Int] ?? [])
    }

    var name: String { didSet { defaults.set(name, forKey: Key.name) } }
    var program: Program { didSet { defaults.set(program.rawValue, forKey: Key.program) } }
    /// Only meaningful for A-level. Stored regardless so switching programme and
    /// back does not silently reset it.
    var examBoard: String { didSet { defaults.set(examBoard, forKey: Key.board) } }
    var load: StudyLoad { didSet { defaults.set(load.rawValue, forKey: Key.load) } }

    /// Set only once onboarding has actually produced an account, so a flow
    /// abandoned halfway is resumed rather than skipped.
    private(set) var hasOnboarded: Bool

    func markOnboarded() {
        hasOnboarded = true
        defaults.set(true, forKey: Key.onboarded)
    }

    /// When the student is willing to work.
    ///
    /// These existed on `Availability` from the start and were never set, so
    /// every student in the app studied 16:00–22:00, seven days a week, with no
    /// way to say otherwise. The defaults deliberately match what was hardcoded,
    /// so nobody's existing plan moves until they actually change something.
    var windowStartHour: Int {
        didSet { defaults.set(windowStartHour, forKey: Key.windowStart) }
    }
    var windowEndHour: Int {
        didSet { defaults.set(windowEndHour, forKey: Key.windowEnd) }
    }
    /// Weekday numbers entirely off, 1 = Sunday per `Calendar`.
    var daysOff: Set<Int> {
        didSet { defaults.set(Array(daysOff).sorted(), forKey: Key.daysOff) }
    }

    /// What the scheduler plans against.
    ///
    /// `Availability`'s own initialiser clamps and orders the hours, so a stored
    /// value that is out of range or inverted cannot reach the scheduler.
    ///
    /// The weekday set it does *not* guard, and a set containing all seven days
    /// leaves the scheduler with nowhere to place anything: every step reports
    /// unplaceable, forever, with no way back except finding the setting again.
    /// These values live in `UserDefaults`, which is writable by anything with
    /// access to the container, so the guard belongs here rather than in the
    /// screen that happens to edit them today.
    var availability: Availability {
        Availability(
            windowStartHour: windowStartHour,
            windowEndHour: windowEndHour,
            dailyCapacityMinutes: load.dailyCapacityMinutes,
            excludedWeekdays: Self.sanitisedDaysOff(daysOff)
        )
    }

    /// Valid weekday numbers only, and never all of them.
    nonisolated static func sanitisedDaysOff(_ raw: Set<Int>) -> Set<Int> {
        let valid = raw.filter { (1...7).contains($0) }
        return valid.count >= 7 ? [] : valid
    }

    /// Used only for the greeting. Empty is fine and common.
    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? ""
    }

    /// What `profiles.curriculum_code` should say.
    var curriculumCode: String { program.curriculumCode(board: examBoard) }

    /// The subjects Albus has verified assessment data for, given what the
    /// student says they study. Empty is the normal case for a programme whose
    /// official documents are not in the corpus yet — every screen that reads
    /// this has to stay useful when it is.
    var curriculumSubjects: [CurriculumSubject] {
        guard let qualification = program.qualification else { return [] }
        return CurriculumSubject.subjects(
            qualification: qualification,
            board: qualification == .aLevel ? examBoard : nil
        )
    }

    /// Boards worth offering. One board is not a choice, so the picker that
    /// reads this hides itself rather than showing a list of length one.
    var availableBoards: [String] {
        program.qualification.map { CurriculumSubject.boards(for: $0) } ?? []
    }
}
