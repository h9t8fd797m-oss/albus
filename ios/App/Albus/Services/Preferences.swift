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
        case ap = "AP"
        case university = "University"
        case other = "Other"
        var id: String { rawValue }
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
        static let load = "albus.profile.load"
        static let onboarded = "albus.profile.onboarded"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        name = defaults.string(forKey: Key.name) ?? ""
        program = Program(rawValue: defaults.string(forKey: Key.program) ?? "") ?? .ib
        load = StudyLoad(rawValue: defaults.string(forKey: Key.load) ?? "") ?? .standard
        hasOnboarded = defaults.bool(forKey: Key.onboarded)
    }

    var name: String { didSet { defaults.set(name, forKey: Key.name) } }
    var program: Program { didSet { defaults.set(program.rawValue, forKey: Key.program) } }
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
}
