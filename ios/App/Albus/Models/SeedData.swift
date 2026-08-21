import Foundation
import SwiftData
import AlbusCore

/// Reproduces the assignments shown in the design exports, so previews and
/// manual checks look like the mockups rather than like lorem ipsum.
enum SeedData {

    @MainActor
    static func populate(_ context: ModelContext, now: Date = .now) {
        let hist = Course(displayName: "HIST 204", colorKey: .red)
        let stat = Course(displayName: "STAT 110", colorKey: .amber)
        let engl = Course(displayName: "ENGL 188", colorKey: .violet)
        for course in [hist, stat, engl] { context.insert(course) }

        let paper = Assignment(
            title: "History Term Paper", taskType: "essay",
            deadline: now.addingTimeInterval(3 * 86_400),
            estimatedMinutes: 365, course: hist
        )
        context.insert(paper)
        let steps: [(String, Int, String?)] = [
            ("Understand the prompt", 15, nil),
            ("Analyze the rubric", 20, "A"),
            ("Research sources", 110, "A"),
            ("Build the outline", 45, "B"),
            ("Write the draft", 120, "B"),
            ("Review & cite", 45, "C"),
            ("Submit", 10, nil)
        ]
        for (i, step) in steps.enumerated() {
            context.insert(Subtask(title: step.0, ordinal: i,
                                   estimatedMinutes: step.1,
                                   criterionCode: step.2, assignment: paper))
        }

        let problemSet = Assignment(
            title: "Statistics Problem Set", taskType: "problem_set",
            deadline: now.addingTimeInterval(5 * 86_400),
            estimatedMinutes: 120, course: stat
        )
        context.insert(problemSet)
        for i in 0..<4 {
            context.insert(Subtask(title: "Questions \(i * 3 + 1)–\(i * 3 + 3)",
                                   ordinal: i, estimatedMinutes: 30,
                                   assignment: problemSet))
        }

        let workshop = Assignment(
            title: "Literary Analysis Essay", taskType: "essay",
            deadline: now.addingTimeInterval(9 * 86_400),
            estimatedMinutes: 180, course: engl
        )
        context.insert(workshop)
        for (i, title) in ["Pick a text", "Draft the argument", "Revise"].enumerated() {
            context.insert(Subtask(title: title, ordinal: i,
                                   estimatedMinutes: 60, assignment: workshop))
        }
    }
}
