import Foundation
import Testing
@testable import Albus

/// The curriculum data is generated and the wiring around it is the kind that
/// fails silently: a plan that is merely *less good* than it should be, with
/// nothing on screen to say so. Both halves are checked here — that the bundled
/// figures are internally consistent, and that a student's programme actually
/// reaches them.
@Suite("Curriculum")
struct CurriculumTests {

    @Test("every subject's components account for the whole qualification")
    func weightingsAreComplete() {
        for subject in CurriculumSubject.all {
            // Grouped by level, because an IB subject carries a separate SL and
            // HL set of components and each must add up on its own.
            let byLevel = Dictionary(grouping: subject.components, by: \.level)
            for (level, components) in byLevel {
                let total = components.reduce(0) { $0 + $1.weighting }
                #expect(abs(total - 100) < 0.51,
                        "\(subject.code)\(level.map { " (\($0))" } ?? "") weightings sum to \(total)")
            }
        }
    }

    @Test("component codes are unique within a subject")
    func componentCodesAreUnique() {
        for subject in CurriculumSubject.all {
            let codes = subject.components.map(\.code)
            #expect(Set(codes).count == codes.count, "\(subject.code) has duplicate components")
        }
    }

    /// Codes travel to the server as lookup keys and are validated there against
    /// `^[A-Z0-9_]{1,64}$`. A generated code that fails that check would be
    /// dropped server-side and cost the student their grounding, silently.
    @Test("every code is one the server will accept")
    func codesMatchTheServersGrammar() {
        func isValid(_ code: String) -> Bool {
            !code.isEmpty && code.count <= 64
                && code.allSatisfy { $0.isUppercase && $0.isLetter || $0.isNumber || $0 == "_" }
        }
        for subject in CurriculumSubject.all {
            #expect(isValid(subject.code), "subject code rejected: \(subject.code)")
            for component in subject.components {
                #expect(isValid(component.code),
                        "component code rejected: \(subject.code)/\(component.code)")
            }
        }
    }

    @Test("assessment objective weightings are ranges, not nonsense")
    func objectiveWeightingsAreSane() {
        for subject in CurriculumSubject.all {
            for objective in subject.objectives {
                if let lo = objective.weightingMin, let hi = objective.weightingMax {
                    #expect(lo <= hi, "\(subject.code) \(objective.code): \(lo) > \(hi)")
                    #expect(lo >= 0 && hi <= 100, "\(subject.code) \(objective.code) out of range")
                }
            }
        }
    }

    @Test("every subject records where its figures came from")
    func sourcesArePresentAndOfficial() {
        for subject in CurriculumSubject.all {
            #expect(subject.source.hasPrefix("https://"), "\(subject.code) has no https source")
            #expect(!subject.retrievedAt.isEmpty, "\(subject.code) has no retrieval date")
        }
    }

    // MARK: - The join between a student's programme and the corpus
    //
    // This is what was actually broken: A-level was the only qualification with
    // verified data and the only one onboarding did not offer, so nothing a
    // student could pick ever reached any of it.

    @MainActor
    @Test("A-level reaches the subjects Albus has data for")
    func aLevelFindsItsSubjects() {
        let preferences = Preferences(defaults: scratchDefaults())
        preferences.program = .aLevel
        preferences.examBoard = "AQA"

        #expect(!preferences.curriculumSubjects.isEmpty,
                "A-level students see no subjects — the corpus is unreachable")
        #expect(preferences.curriculumCode == "A_LEVEL_AQA")
    }

    @MainActor
    @Test("a programme with no corpus offers nothing rather than something wrong")
    func programmesWithoutDataStayEmpty() {
        let preferences = Preferences(defaults: scratchDefaults())
        for program in [Preferences.Program.university, .other] {
            preferences.program = program
            #expect(preferences.curriculumSubjects.isEmpty)
            #expect(preferences.curriculumCode == "GENERIC")
        }
    }

    @MainActor
    @Test("the board is part of an A-level subject's identity")
    func boardNarrowsTheSubjectList() {
        let preferences = Preferences(defaults: scratchDefaults())
        preferences.program = .aLevel
        preferences.examBoard = "NOT_A_BOARD"

        // Not a crash and not somebody else's specification: a board we hold
        // nothing for has no subjects, which is the honest answer.
        #expect(preferences.curriculumSubjects.isEmpty)
    }

    // MARK: - What the add-assignment sheet reads
    //
    // The picker hides itself when a subject has no components, so a code that
    // stops resolving does not break a screen — it silently removes the
    // question, and every plan for that subject quietly loses its grounding.

    @Test("a curriculum subject resolves to its components")
    func courseFindsItsComponents() {
        let subject = try! #require(CurriculumSubject.all.first)
        let course = Course(displayName: subject.shortName,
                            curriculumSubjectCode: subject.code)

        #expect(course.curriculum?.code == subject.code)

        let components = course.curriculum?.components ?? []
        #expect(components.count > 0,
                "\(subject.code) resolves but offers no components to pick")
    }

    @Test("a subject the student named themselves resolves to nothing")
    func handTypedCoursesHaveNoCurriculum() {
        #expect(Course(displayName: "History HL").curriculum == nil)
        #expect(Course(displayName: "Biology", curriculumSubjectCode: "GONE").curriculum == nil)
    }

    @Test("a component reads as something a student recognises")
    func componentsDescribeThemselves() {
        for subject in CurriculumSubject.all {
            for component in subject.components {
                #expect(component.pickerTitle.contains(component.name))
                // A duration of exactly n hours must not read "2h 0m".
                if let minutes = component.minutes, minutes % 60 == 0 {
                    #expect(component.durationText == "\(minutes / 60)h")
                }
                #expect(!component.weightingText.contains("."),
                        "\(subject.code)/\(component.code) shows a fractional weighting")
            }
        }
    }

    /// A throwaway `UserDefaults` so a test cannot overwrite the simulator's
    /// real profile — or read one a previous test left behind.
    private func scratchDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!
        return suite
    }
}
