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

    /// What the scheduler plans against.
    var availability: Availability {
        Availability(dailyCapacityMinutes: load.dailyCapacityMinutes)
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
