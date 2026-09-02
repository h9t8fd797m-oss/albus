import Foundation
import Testing
@testable import Albus

@MainActor
@Suite("Entitlement refresh")
struct EntitlementServiceTests {

    private enum StubFailure: Error { case offline }

    private actor StubReader: PlanReading {
        enum Mode: Sendable {
            case fail
            case succeed(EntitlementService.Plan?)
        }

        private var mode: Mode

        init(_ mode: Mode) { self.mode = mode }

        func set(_ mode: Mode) { self.mode = mode }

        func fetch() async throws -> EntitlementService.Plan? {
            switch mode {
            case .fail: throw StubFailure.offline
            case .succeed(let plan): return plan
            }
        }
    }

    @Test("a failed refresh keeps the previous plan and exposes stale state")
    func failureIsVisibleWithoutDowngrading() async {
        let reader = StubReader(.fail)
        let service = EntitlementService(reader: reader)

        await service.refresh()

        #expect(service.plan == .freeFallback)
        #expect(service.lastCheckedAt == nil)
        #expect(service.refreshFailed)
    }

    @Test("dismissal hides only the warning")
    func dismissalDoesNotChangeThePlan() async {
        let reader = StubReader(.fail)
        let service = EntitlementService(reader: reader)
        await service.refresh()
        let plan = service.plan

        service.dismissRefreshFailure()

        #expect(!service.refreshFailed)
        #expect(service.plan == plan)
    }

    @Test("a later successful refresh clears stale state")
    func successClearsTheFailure() async {
        let reader = StubReader(.fail)
        let service = EntitlementService(reader: reader)
        await service.refresh()
        await reader.set(.succeed(.freeFallback))

        await service.refresh()

        #expect(!service.refreshFailed)
        #expect(service.lastCheckedAt != nil)
    }
}
