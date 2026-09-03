import Testing
import Foundation
@testable import Albus

/// `TaskType`'s raw values are a wire contract shared by three places: this
/// enum, `assignments_task_type_check` in Postgres, and `TASK_TYPES` in the
/// breakdown Edge Function. They drifted once already — onboarding offered six
/// types while task creation offered eight — and nothing caught it, because
/// nothing was checking.
///
/// These tests pin the shape. The cross-system agreement itself is asserted in
/// `supabase/tests/production_safety_test.sql`, which can see the real
/// constraint; what can be checked here is that the client's own list is
/// complete, stable, and degrades safely.
@Suite("Task types")
struct TaskTypeTests {

    /// The exact set the server accepts, transcribed from the migration and the
    /// Edge Function. If this test fails, one of the three lists moved without
    /// the others — which is the bug it exists to catch, not a reason to edit
    /// this array until it goes green.
    private static let serverAccepted: Set<String> = [
        "essay", "problem_set", "lab_report", "reading",
        "revision", "project", "presentation", "other",
        "internal_assessment", "extended_essay",
        "tok_essay", "tok_exhibition",
        "mock_exam", "final_exam"
    ]

    @Test("every client type is one the server accepts")
    func noClientTypeTheServerRejects() {
        let client = Set(TaskType.allCases.map(\.rawValue))
        let unknownToServer = client.subtracting(Self.serverAccepted)
        #expect(unknownToServer.isEmpty,
                "these would 422 on the student with nothing they could do: \(unknownToServer.sorted())")
    }

    @Test("every type the server accepts is offered to the student")
    func noServerTypeTheClientHides() {
        let client = Set(TaskType.allCases.map(\.rawValue))
        let unofferedByClient = Self.serverAccepted.subtracting(client)
        #expect(unofferedByClient.isEmpty,
                "the server would accept these but nothing can send them: \(unofferedByClient.sorted())")
    }

    @Test("both entry points offer the same list")
    func onboardingAndTaskCreationAgree() {
        // The original bug: OnboardingFlow had six, AddTaskSheet had eight.
        // Both read `offered` now, so this holds by construction — the test is
        // here so that reintroducing a second hand-written list fails loudly.
        #expect(Set(TaskType.offered) == Set(TaskType.allCases))
        #expect(TaskType.offered.count == TaskType.allCases.count,
                "offered must not drop or duplicate a type")
    }

    // MARK: - Classification

    @Test("exactly the six IB assessments are marked as such")
    func ibAssessmentsAreTheSix() {
        let flagged = Set(TaskType.allCases.filter(\.isIBAssessment).map(\.rawValue))
        #expect(flagged == [
            "internal_assessment", "extended_essay",
            "tok_essay", "tok_exhibition",
            "mock_exam", "final_exam"
        ])
    }

    @Test("only mocks and finals count as exam preparation")
    func examPreparationIsRevisionOnly() {
        // The distinction the planner needs: these produce no deliverable, so
        // they are planned as practice and recall, not as drafting.
        let flagged = Set(TaskType.allCases.filter(\.isExamPreparation).map(\.rawValue))
        #expect(flagged == ["mock_exam", "final_exam"])

        // An IA is an IB assessment but is emphatically *not* exam prep — it
        // has a deliverable. Getting this backwards would plan months of
        // coursework as revision.
        #expect(TaskType.internalAssessment.isIBAssessment)
        #expect(!TaskType.internalAssessment.isExamPreparation)
    }

    @Test("the two TOK assessments are distinct types")
    func tokEssayAndExhibitionAreSeparate() {
        // They have different criteria and different work: three objects and a
        // commentary versus one prescribed title. Collapsing them would give a
        // student the wrong plan for whichever one they are actually doing.
        #expect(TaskType.tokEssay != TaskType.tokExhibition)
        #expect(TaskType.tokEssay.isIBAssessment)
        #expect(TaskType.tokExhibition.isIBAssessment)
    }

    // MARK: - Degrading safely

    @Test("an unknown stored value falls back instead of failing")
    func unknownValueFallsBack() {
        // A newer build writing a type this one does not know must not make the
        // task unreadable. Better a task labelled "Other" than a task that
        // cannot be opened.
        #expect(TaskType(storedValue: "some_future_type") == .other)
        #expect(TaskType(storedValue: nil) == .other)
        #expect(TaskType(storedValue: "") == .other)
    }

    @Test("known values still round-trip exactly")
    func knownValuesRoundTrip() {
        for type in TaskType.allCases {
            #expect(TaskType(storedValue: type.rawValue) == type,
                    "\(type.rawValue) did not round-trip")
        }
    }

    @Test("raw values are stable snake_case, never display text")
    func rawValuesAreWireSafe() {
        for type in TaskType.allCases {
            #expect(type.rawValue.wholeMatch(of: /[a-z_]+/) != nil,
                    "\(type.rawValue) is not a safe wire value")
            // A raw value that leaked display text would break every stored row
            // the moment the copy was reworded.
            #expect(type.rawValue != type.title)
        }
    }

    // MARK: - Estimates

    @Test("every type has a usable default duration")
    func defaultsAreSane() {
        for type in TaskType.allCases {
            // The server rejects anything outside 5–12000 minutes.
            #expect(type.defaultMinutes >= 5 && type.defaultMinutes <= 12_000,
                    "\(type.rawValue) defaults outside what the server accepts")
        }
    }

    @Test("the long IB pieces default longer than ordinary homework")
    func ibPiecesDefaultLonger() {
        // Not a claim about total effort — the scheduler places sessions, not
        // whole projects. Just that a session on an extended essay should not
        // default shorter than a session of reading.
        #expect(TaskType.extendedEssay.defaultMinutes > TaskType.reading.defaultMinutes)
        #expect(TaskType.internalAssessment.defaultMinutes > TaskType.reading.defaultMinutes)
    }
}
