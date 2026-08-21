import Testing
import SwiftData
import Foundation
@testable import Albus
import AlbusCore

/// Exercises the store, the bridge and the scheduler together.
///
/// The unit tests in AlbusCore prove the scheduler is correct on value types.
/// These prove the app actually feeds it the right values and writes the
/// answer back — the seam where a persistence bug would hide.
@MainActor
@Suite("Data layer")
struct DataLayerTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Course.self, Assignment.self, Subtask.self,
                             PlanSessionRecord.self, CompletionRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("the schema opens and seeds")
    func schemaIsValid() throws {
        let ctx = try makeContext()
        SeedData.populate(ctx)
        try ctx.save()

        let assignments = try ctx.fetch(FetchDescriptor<Assignment>())
        #expect(assignments.count == 3)
        let subtasks = try ctx.fetch(FetchDescriptor<Subtask>())
        #expect(subtasks.count == 14)
    }

    @Test("only incomplete work is handed to the scheduler")
    func excludesCompletedWork() throws {
        let ctx = try makeContext()
        SeedData.populate(ctx)
        try ctx.save()

        var assignments = try ctx.fetch(FetchDescriptor<Assignment>())
        let before = PlanBridge.scheduleItems(from: assignments).count

        // Finish one step.
        assignments[0].subtasks.first?.completedAt = .now
        try ctx.save()

        assignments = try ctx.fetch(FetchDescriptor<Assignment>())
        #expect(PlanBridge.scheduleItems(from: assignments).count == before - 1)
    }

    @Test("archived assignments are not scheduled")
    func excludesArchived() throws {
        let ctx = try makeContext()
        SeedData.populate(ctx)
        try ctx.save()

        var assignments = try ctx.fetch(FetchDescriptor<Assignment>())
        let before = PlanBridge.scheduleItems(from: assignments).count
        let archivedSteps = assignments[0].subtasks.count
        assignments[0].status = "archived"
        try ctx.save()

        assignments = try ctx.fetch(FetchDescriptor<Assignment>())
        #expect(PlanBridge.scheduleItems(from: assignments).count == before - archivedSteps)
    }

    @Test("a schedule round-trips into the store")
    func schedulePersists() throws {
        let ctx = try makeContext()
        let now = Date(timeIntervalSince1970: 1_779_000_000)
        SeedData.populate(ctx, now: now)
        try ctx.save()

        let assignments = try ctx.fetch(FetchDescriptor<Assignment>())
        let items = PlanBridge.scheduleItems(from: assignments)
        let result = Scheduler().schedule(items: items, now: now)

        let subtasks = try ctx.fetch(FetchDescriptor<Subtask>())
        let byID = Dictionary(subtasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        PlanBridge.apply(result, to: ctx, subtasksByID: byID, existing: [])
        try ctx.save()

        let written = try ctx.fetch(FetchDescriptor<PlanSessionRecord>())
        #expect(written.count == result.sessions.count)
        #expect(!written.isEmpty)
        for record in written { #expect(record.subtask != nil, "session lost its step") }
    }

    @Test("re-planning updates in place instead of churning rows")
    func replanReconciles() throws {
        let ctx = try makeContext()
        let now = Date(timeIntervalSince1970: 1_779_000_000)
        SeedData.populate(ctx, now: now)
        try ctx.save()

        let assignments = try ctx.fetch(FetchDescriptor<Assignment>())
        let items = PlanBridge.scheduleItems(from: assignments)
        let subtasks = try ctx.fetch(FetchDescriptor<Subtask>())
        let byID = Dictionary(subtasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let first = Scheduler().schedule(items: items, now: now)
        PlanBridge.apply(first, to: ctx, subtasksByID: byID, existing: [])
        try ctx.save()

        let firstRecords = try ctx.fetch(FetchDescriptor<PlanSessionRecord>())
        let firstIDs = Set(firstRecords.map(\.id))

        // Nothing about the world changed, so the same rows should survive.
        let second = Scheduler().schedule(
            items: items,
            existing: PlanBridge.plannedSessions(from: firstRecords),
            now: now
        )
        PlanBridge.apply(second, to: ctx, subtasksByID: byID, existing: firstRecords)
        try ctx.save()

        let secondRecords = try ctx.fetch(FetchDescriptor<PlanSessionRecord>())
        #expect(Set(secondRecords.map(\.id)) == firstIDs, "re-plan tore down and rebuilt rows")
        #expect(second.movedCount == 0)
    }

    @Test("fixed commitments are never deleted by a re-plan")
    func fixedCommitmentsSurvive() throws {
        let ctx = try makeContext()
        let now = Date(timeIntervalSince1970: 1_779_000_000)
        SeedData.populate(ctx, now: now)

        let klass = PlanSessionRecord(startsAt: now.addingTimeInterval(3600),
                                      endsAt: now.addingTimeInterval(7200),
                                      isFixed: true)
        ctx.insert(klass)
        try ctx.save()

        let assignments = try ctx.fetch(FetchDescriptor<Assignment>())
        let subtasks = try ctx.fetch(FetchDescriptor<Subtask>())
        let byID = Dictionary(subtasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let existing = try ctx.fetch(FetchDescriptor<PlanSessionRecord>())

        let result = Scheduler().schedule(
            items: PlanBridge.scheduleItems(from: assignments),
            commitments: PlanBridge.commitments(from: existing),
            now: now
        )
        PlanBridge.apply(result, to: ctx, subtasksByID: byID, existing: existing)
        try ctx.save()

        let after = try ctx.fetch(FetchDescriptor<PlanSessionRecord>())
        #expect(after.contains { $0.id == klass.id }, "a re-plan deleted a class")
    }

    @Test("completion records carry no free text")
    func logsCarryNoContent() throws {
        let ctx = try makeContext()
        let log = CompletionRecord(subjectCode: "HIST", taskType: "essay",
                                   estimatedMinutes: 60, actualMinutes: 90)
        ctx.insert(log)
        try ctx.save()

        // The privacy guarantee is structural: there is no field that could
        // hold a title or note, so one cannot be added by accident.
        let mirror = Mirror(reflecting: log)
        let names = Set(mirror.children.compactMap(\.label))
        #expect(!names.contains("title"))
        #expect(!names.contains("notes"))
        #expect(!names.contains("guidance"))
    }
}
