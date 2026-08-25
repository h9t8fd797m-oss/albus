import Foundation
import SwiftData
import Testing
@testable import Albus

/// Cost of selection, measured rather than assumed.
///
/// `suggested(for:)` is called from a SwiftUI view body, once per visible step,
/// on every render pass. Anything superlinear in the number of steps is paid
/// again every time the list redraws.
@MainActor
@Suite("Tool selection — cost")
struct ToolSelectionPerfTests {

    @Test("selecting for a whole plan stays cheap enough to run in a view body")
    func wholePlanSelectionIsFast() throws {
        let container = try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        let course = Course(displayName: "History")
        ctx.insert(course)
        let assignment = Assignment(
            title: "Essay", taskType: "essay",
            deadline: Calendar.current.date(byAdding: .day, value: 14, to: now)!,
            estimatedMinutes: 900, course: course)
        ctx.insert(assignment)

        // The server caps a plan at 12 steps; 20 is the database ceiling.
        let needs = StudyTool.Need.allCases
        for i in 0..<20 {
            ctx.insert(Subtask(title: "Step \(i)", ordinal: i, estimatedMinutes: 45,
                               toolNeed: needs[i % needs.count].rawValue,
                               assignment: assignment))
        }
        let steps = assignment.subtasks.sorted { $0.ordinal < $1.ordinal }

        // One render pass of the whole list, the way the screen does it.
        let started = Date()
        for _ in 0..<10 {
            _ = StudyTool.suggestions(forPlanOf: assignment, now: now)
        }
        let perPass = Date().timeIntervalSince(started) / 10
        _ = steps

        print("── whole-plan selection: \(String(format: "%.2f", perPass * 1000))ms per render pass (20 steps)")
        // A render pass has ~16ms to do everything. Selection must be a small
        // fraction of that, not most of it.
        #expect(perPass < 0.008,
                "selection costs \(String(format: "%.1f", perPass * 1000))ms per pass — too much for a view body")
    }
}
