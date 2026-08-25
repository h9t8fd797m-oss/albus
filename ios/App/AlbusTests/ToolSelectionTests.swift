import Foundation
import SwiftData
import Testing
@testable import Albus

/// The tool selector.
///
/// The bar these tests hold it to is not "picks something sensible" but "picks
/// something *different* when the context differs". The version this replaced
/// passed every sensibleness check and still gave every student the same two
/// tools, because it never looked at anything but the words in the title.
@MainActor
@Suite("Tool selection")
struct ToolSelectionTests {

    // MARK: - Fixtures

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true)
        )
    }

    /// One assignment with one step, built from the context under test.
    private func step(
        _ context: ModelContext,
        need: StudyTool.Need?,
        title: String = "Do the thing",
        subject: String? = nil,
        curriculumCode: String? = nil,
        taskType: String = "essay",
        daysToDeadline: Int = 14,
        stepMinutes: Int = 60,
        now: Date = Date(timeIntervalSince1970: 1_770_000_000)
    ) -> Subtask {
        let course = subject.map {
            Course(displayName: $0, curriculumSubjectCode: curriculumCode)
        }
        if let course { context.insert(course) }
        let assignment = Assignment(
            title: "Assignment", taskType: taskType,
            deadline: Calendar.current.date(byAdding: .day, value: daysToDeadline, to: now)!,
            estimatedMinutes: 600, course: course
        )
        context.insert(assignment)
        let s = Subtask(title: title, ordinal: 0, estimatedMinutes: stepMinutes,
                        toolNeed: need?.rawValue, assignment: assignment)
        context.insert(s)
        return s
    }

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - The thing that was broken

    @Test("the same need in different subjects gives different tools")
    func subjectChangesTheAnswer() throws {
        let ctx = ModelContext(try container())
        let history = StudyTool.suggested(
            for: step(ctx, need: .sourceResearch, subject: "History"), now: now)
        let biology = StudyTool.suggested(
            for: step(ctx, need: .sourceResearch, subject: "Biology"), now: now)

        #expect(!history.isEmpty && !biology.isEmpty)
        #expect(history != biology,
                "same tools for History and Biology: \(history.map(\.name))")
        // And specifically the right way round.
        #expect(history.contains(.jstor), "History source work should reach JSTOR")
        #expect(biology.contains(.pubmed), "Biology source work should reach PubMed")
    }

    @Test("the same subject with different needs gives different tools")
    func needChangesTheAnswer() throws {
        let ctx = ModelContext(try container())
        var seen: [StudyTool.Need: [StudyTool]] = [:]
        for need in [StudyTool.Need.sourceResearch, .outlining, .drafting,
                     .editing, .proofreading, .citation] {
            seen[need] = StudyTool.suggested(for: step(ctx, need: need, subject: "History"), now: now)
        }
        for (need, tools) in seen {
            #expect(!tools.isEmpty, "\(need.rawValue) produced nothing")
        }
        // Six stages of one essay must not collapse onto one answer.
        let distinct = Set(seen.values.map { $0.map(\.name).joined(separator: "|") })
        #expect(distinct.count == seen.count,
                "different needs produced identical tool lists")
    }

    @Test("a tight deadline stops Albus suggesting something you must install")
    func deadlinePressureDemotesHeavyTools() throws {
        let ctx = ModelContext(try container())
        let roomy = StudyTool.suggested(
            for: step(ctx, need: .citation, subject: "History", daysToDeadline: 21), now: now)
        let tomorrow = StudyTool.suggested(
            for: step(ctx, need: .citation, subject: "History", daysToDeadline: 1), now: now)

        #expect(roomy.first?.setup == .heavy,
                "with three weeks, a reference manager is the right answer")
        #expect(tomorrow.first?.setup == .light,
                "due tomorrow, the first suggestion must not need installing — got \(tomorrow.first?.name ?? "none")")
    }

    @Test("a maths tool is not offered for a history essay, or the reverse")
    func subjectSpecificToolsStayInTheirSubject() throws {
        let ctx = ModelContext(try container())
        let history = StudyTool.suggested(
            for: step(ctx, need: .workedExamples, subject: "History"), now: now)
        #expect(!history.contains(.photomath), "Photomath for a history step")
        #expect(!history.contains(.symbolab), "Symbolab for a history step")

        let maths = StudyTool.suggested(
            for: step(ctx, need: .workedExamples, subject: "Mathematics"), now: now)
        #expect(maths.contains { $0.areas.contains(.maths) },
                "a maths step reached no maths tool: \(maths.map(\.name))")
    }

    @Test("one plan does not recommend the same tool at every step")
    func aPlanVariesAcrossItsSteps() throws {
        let ctx = ModelContext(try container())
        let course = Course(displayName: "English Literature")
        ctx.insert(course)
        let assignment = Assignment(
            title: "Comparative essay", taskType: "essay",
            deadline: Calendar.current.date(byAdding: .day, value: 14, to: now)!,
            estimatedMinutes: 600, course: course
        )
        ctx.insert(assignment)

        let needs: [StudyTool.Need] = [.sourceResearch, .reading, .outlining,
                                       .drafting, .editing, .proofreading]
        for (i, need) in needs.enumerated() {
            ctx.insert(Subtask(title: "Step \(i)", ordinal: i, estimatedMinutes: 60,
                               toolNeed: need.rawValue, assignment: assignment))
        }

        let firstChoices = assignment.subtasks
            .sorted { $0.ordinal < $1.ordinal }
            .compactMap { StudyTool.suggested(for: $0, now: now).first }

        #expect(firstChoices.count == needs.count)
        #expect(Set(firstChoices).count == firstChoices.count,
                "a six-step plan repeated a tool: \(firstChoices.map(\.name))")
    }

    @Test("repeated needs in one plan still get different tools")
    func repeatedNeedsDoNotRepeatTools() throws {
        // A real maths plan looks like this: practise, check, practise, practise.
        // Three problem_practice steps must not all point at the same site.
        let ctx = ModelContext(try container())
        let course = Course(displayName: "Mathematics")
        ctx.insert(course)
        let assignment = Assignment(
            title: "Integration problem set", taskType: "problem_set",
            deadline: Calendar.current.date(byAdding: .day, value: 5, to: now)!,
            estimatedMinutes: 240, course: course)
        ctx.insert(assignment)

        let needs: [StudyTool.Need] = [.workedExamples, .problemPractice,
                                       .errorAnalysis, .problemPractice, .problemPractice]
        for (i, need) in needs.enumerated() {
            ctx.insert(Subtask(title: "Step \(i)", ordinal: i, estimatedMinutes: 45,
                               toolNeed: need.rawValue, assignment: assignment))
        }

        let practice = assignment.subtasks
            .sorted { $0.ordinal < $1.ordinal }
            .filter { $0.need == .problemPractice }
            .compactMap { StudyTool.suggested(for: $0, now: now).first }

        #expect(practice.count == 3)
        #expect(Set(practice).count == 3,
                "three practice steps gave \(Set(practice).count) distinct tools: \(practice.map(\.name))")
    }

    // MARK: - Determinism and bounds

    @Test("the same context always gives the same answer")
    func selectionIsDeterministic() throws {
        let ctx = ModelContext(try container())
        let a = StudyTool.suggested(for: step(ctx, need: .drafting, subject: "History"), now: now)
        let b = StudyTool.suggested(for: step(ctx, need: .drafting, subject: "History"), now: now)
        #expect(a == b, "two identical steps produced different tools")
    }

    @Test("every need in the vocabulary reaches at least one tool")
    func noNeedIsADeadEnd() throws {
        let ctx = ModelContext(try container())
        // A need the planner can emit but nothing serves shows the student an
        // empty row that looks like a bug.
        for need in StudyTool.Need.allCases {
            let tools = StudyTool.suggested(for: step(ctx, need: need, subject: "History"), now: now)
            #expect(!tools.isEmpty, "\(need.rawValue) reaches no tool")
        }
    }

    @Test("a step with no need and no recognisable words offers nothing, not noise")
    func unknownStepsStaySilent() throws {
        let ctx = ModelContext(try container())
        let s = step(ctx, need: nil, title: "Zzzz qqqq", subject: "History")
        s.guidance = "Mmm."
        #expect(StudyTool.suggested(for: s, now: now).isEmpty,
                "invented a recommendation for a step it did not understand")
    }

    @Test("old plans with no recorded need still get sensible tools")
    func legacyStepsFallBackToTheirWords() throws {
        let ctx = ModelContext(try container())
        let s = step(ctx, need: nil, title: "Find and skim three sources on the 1848 revolutions",
                     subject: "History")
        let tools = StudyTool.suggested(for: s, now: now)
        #expect(!tools.isEmpty)
        #expect(tools.allSatisfy { $0.needs.contains(.sourceResearch) })
    }

    @Test("never returns more than the row can show")
    func resultIsBounded() throws {
        let ctx = ModelContext(try container())
        for need in StudyTool.Need.allCases {
            #expect(StudyTool.suggested(for: step(ctx, need: need, subject: "Biology"), now: now).count <= 3)
        }
    }

    // MARK: - Trying to break it

    @Test("a step with no assignment still works")
    func orphanStepDoesNotCrash() throws {
        // Reachable while a plan is being edited, and from any preview.
        let ctx = ModelContext(try container())
        let orphan = Subtask(title: "Draft it", ordinal: 0, estimatedMinutes: 60,
                             toolNeed: StudyTool.Need.drafting.rawValue)
        ctx.insert(orphan)
        #expect(!StudyTool.suggested(for: orphan, now: now).isEmpty)
    }

    @Test("an overdue assignment is treated as maximum pressure, not negative time")
    func overdueDeadlineClampsRatherThanInverts() throws {
        let ctx = ModelContext(try container())
        let overdue = StudyTool.suggested(
            for: step(ctx, need: .citation, subject: "History", daysToDeadline: -30), now: now)
        #expect(!overdue.isEmpty)
        #expect(overdue.first?.setup == .light,
                "an overdue assignment offered a tool that needs installing")
    }

    @Test("a need served only by heavy tools still returns something when time is short")
    func neverReturnsNothingJustBecauseTimeIsShort() throws {
        // The setup penalty demotes; it must never filter. A student with no
        // time still deserves the best available answer.
        let ctx = ModelContext(try container())
        for need in StudyTool.Need.allCases {
            let tools = StudyTool.suggested(
                for: step(ctx, need: need, subject: "Biology", daysToDeadline: 0, stepMinutes: 5),
                now: now)
            #expect(!tools.isEmpty, "\(need.rawValue) returned nothing under deadline pressure")
        }
    }

    @Test("a need this build does not recognise falls back rather than crashing")
    func unknownNeedFromANewerServerIsIgnored() throws {
        let ctx = ModelContext(try container())
        let s = step(ctx, need: nil, title: "Find three sources on trade unions", subject: "History")
        s.toolNeed = "quantum_telepathy"   // a need added server-side after this build shipped
        #expect(s.need == nil)
        // Falls through to the words in the step, which are unambiguous here.
        let tools = StudyTool.suggested(for: s, now: now)
        #expect(tools.allSatisfy { $0.needs.contains(.sourceResearch) })
    }

    @Test("non-contiguous ordinals do not break the diversity pass")
    func gappedOrdinalsStillVary() throws {
        // Deleting a step leaves gaps until the next renumber.
        let ctx = ModelContext(try container())
        let course = Course(displayName: "History")
        ctx.insert(course)
        let assignment = Assignment(
            title: "Essay", taskType: "essay",
            deadline: Calendar.current.date(byAdding: .day, value: 10, to: now)!,
            estimatedMinutes: 600, course: course)
        ctx.insert(assignment)
        for ordinal in [0, 7, 41] {
            ctx.insert(Subtask(title: "Step", ordinal: ordinal, estimatedMinutes: 60,
                               toolNeed: StudyTool.Need.sourceResearch.rawValue,
                               assignment: assignment))
        }
        let picks = assignment.subtasks
            .sorted { $0.ordinal < $1.ordinal }
            .compactMap { StudyTool.suggested(for: $0, now: now).first }
        #expect(Set(picks).count == picks.count, "gapped ordinals repeated a tool")
    }

    @Test("a subject Albus has never heard of still gets general tools")
    func unknownSubjectDegradesToGeneral() throws {
        let ctx = ModelContext(try container())
        let tools = StudyTool.suggested(
            for: step(ctx, need: .drafting, subject: "Underwater Basket Weaving"), now: now)
        #expect(!tools.isEmpty)
        // No subject match, so nothing subject-specific should be claimed.
        #expect(tools.allSatisfy { $0.areas.isEmpty },
                "claimed a subject-specific tool for an unknown subject: \(tools.map(\.name))")
    }

    // MARK: - The catalogue is actually reachable

    @Test("selection reaches far more of the catalogue than the fourteen it replaced")
    func mostOfTheCatalogueIsReachable() throws {
        let ctx = ModelContext(try container())
        var reached: Set<StudyTool> = []
        let subjects: [(String, String?)] = [
            ("History", nil), ("Biology", nil), ("Mathematics", nil), ("Spanish B", nil),
            ("Computer Science", nil), ("Visual Arts", nil), ("Economics", nil), ("Physics", nil),
        ]
        for (subject, code) in subjects {
            for need in StudyTool.Need.allCases {
                for days in [1, 3, 21] {
                    reached.formUnion(StudyTool.suggested(
                        for: step(ctx, need: need, subject: subject, curriculumCode: code,
                                  daysToDeadline: days),
                        now: now))
                }
            }
        }
        // The old keyword matcher could only ever return 14 tools in total.
        #expect(reached.count >= 90,
                "only \(reached.count) of \(StudyTool.allCases.count) tools are reachable")
    }
}
