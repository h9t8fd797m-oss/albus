import Foundation
import SwiftData
import Testing
@testable import Albus

/// Not an assertion — a printout, for reading recommendations the way a student
/// would see them. Kept because "the tests pass" and "the suggestions make
/// sense" are different claims, and only one of them can be automated.
@MainActor
@Suite("Tool selection — inspection")
struct ToolSelectionDumpTests {

    @Test("dump recommendations across subjects, needs and deadlines")
    func dump() throws {
        let container = try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        let cases: [(subject: String, task: String, needs: [StudyTool.Need])] = [
            ("History", "essay", [.sourceResearch, .reading, .outlining, .drafting, .editing, .citation]),
            ("Biology", "lab_report", [.simulation, .dataAnalysis, .diagramming, .drafting, .errorAnalysis]),
            ("Mathematics", "problem_set", [.workedExamples, .problemPractice, .errorAnalysis, .computation, .graphing]),
            ("Spanish B", "revision", [.vocabulary, .translation, .listeningSpeaking, .spacedPractice]),
            ("Computer Science", "project", [.coding, .debugging, .problemPractice, .planning]),
            ("Visual Arts", "project", [.design, .presentation, .diagramming]),
            ("Economics", "essay", [.dataAnalysis, .sourceResearch, .outlining, .selfTesting]),
            ("Physics", "revision", [.selfTesting, .memorisation, .workedExamples, .focus]),
        ]

        for (subject, task, needs) in cases {
            print("\n═══ \(subject) · \(task)")
            let course = Course(displayName: subject)
            ctx.insert(course)
            for days in [1, 14] {
                print("  ── \(days) day\(days == 1 ? "" : "s") to deadline")
                let assignment = Assignment(
                    title: "\(subject) task", taskType: task,
                    deadline: Calendar.current.date(byAdding: .day, value: days, to: now)!,
                    estimatedMinutes: 600, course: course)
                ctx.insert(assignment)
                for (i, need) in needs.enumerated() {
                    let s = Subtask(title: "Step \(i)", ordinal: i, estimatedMinutes: 45,
                                    toolNeed: need.rawValue, assignment: assignment)
                    ctx.insert(s)
                    let tools = StudyTool.suggested(for: s, now: now)
                    print("     \(need.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) → "
                          + tools.map(\.name).joined(separator: ", "))
                }
            }
        }
    }
}
