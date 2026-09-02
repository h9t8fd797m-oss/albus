import Foundation
import Supabase
import Testing
@testable import Albus

/// The planning endpoint turns one sentence into the work a student actually
/// follows. These tests pin the transport contract: server failures must become
/// useful, closed client states, and a valid response must keep every piece of
/// rubric grounding that the UI relies on.
@Suite("Plan service")
struct PlanServiceTests {

    private func serverError(_ serverCode: String? = nil, status: Int = 502,
                             message: String? = nil) -> FunctionsError {
        var body: [String: String] = [:]
        if let serverCode { body["error"] = serverCode }
        if let message { body["message"] = message }
        let data = try! JSONSerialization.data(withJSONObject: body)
        return .httpError(code: status, data: data)
    }

    /// Old app versions remain in students' hands after the server changes.
    /// The retired Free-only code and the current plan-aware code must continue
    /// to lead to the same task-limit explanation.
    @Test("both generations of task-limit code remain understood")
    func taskLimitCompatibility() {
        for code in ["PLAN_TASK_LIMIT_REACHED", "FREE_PLAN_LIMIT_REACHED"] {
            #expect(PlanService.translate(serverError(code)) == .quotaReached)
        }
    }

    /// A burst limit recovers shortly; the rolling safety ceiling does not.
    /// Collapsing them would tell a student to retry an action the server will
    /// keep refusing.
    @Test("temporary and rolling limits stay distinct")
    func limitsStayDistinct() {
        for code in ["RATE_LIMIT_HOURLY", "RATE_LIMIT_DAILY"] {
            #expect(PlanService.translate(serverError(code)) == .rateLimited)
        }
        #expect(PlanService.translate(serverError("FAIR_USE_REACHED")) == .fairUseReached)
        #expect(PlanService.translate(serverError("GLOBAL_CAPACITY_REACHED")) == .unavailable)
    }

    /// Empty text and malformed structured output are different diagnostics on
    /// the server, but the same action for a student: retry once. This is the
    /// item-4 behavior item 5 is required to pin.
    @Test("unusable model answers ask for one retry")
    func unusableAnswersAreRetryable() {
        for code in ["EMPTY_RESPONSE", "MALFORMED_RESPONSE"] {
            let failure = PlanService.translate(serverError(code))
            #expect(failure == .unusableResponse)
            #expect(failure.errorDescription == ModelResponseFailure.retryableDescription)
        }
    }

    /// If an older or newer server omits a machine code, the HTTP status still
    /// gives the client a safe fallback. No raw body is needed for these paths.
    @Test("known HTTP statuses retain safe fallbacks")
    func statusFallbacks() {
        let cases: [(Int, PlanService.Failure)] = [
            (402, .quotaReached),
            (429, .rateLimited),
            (413, .rejected("Albus couldn't plan that.")),
            (422, .rejected("Albus couldn't plan that.")),
            (500, .unavailable),
        ]

        for (status, expected) in cases {
            #expect(PlanService.translate(serverError(status: status)) == expected)
        }
    }

    /// Validation messages are written for the student by the server and are
    /// safe to preserve. Infrastructure messages are not: a 500 must collapse
    /// to the closed unavailable state even if its body contains details.
    @Test("only actionable rejection copy reaches the screen")
    func messageExposureIsScoped() {
        let guidance = "Choose a deadline after today."
        #expect(PlanService.translate(serverError(status: 422, message: guidance))
                == .rejected(guidance))

        let internalDetail = "connection refused at private-database:5432"
        let failure = PlanService.translate(serverError(status: 500, message: internalDetail))
        #expect(failure == .unavailable)
        #expect(failure.errorDescription?.contains(internalDetail) == false)
    }

    @Test("a relay failure is an outage rather than a student error")
    func relayFailureIsUnavailable() {
        #expect(PlanService.translate(.relayError) == .unavailable)
    }

    /// This JSON is the public contract of the breakdown Edge Function. The
    /// snake-case keys are deliberately explicit so a Swift rename cannot
    /// silently discard criterion grounding or tool selection.
    @Test("a rubric-grounded plan decodes without losing context")
    func groundedResultDecodes() throws {
        let assignmentID = UUID(uuidString: "2E4D57AE-99F4-48DC-80E1-39D77AA3B63F")!
        let json = #"""
        {
          "assignment_id": "2E4D57AE-99F4-48DC-80E1-39D77AA3B63F",
          "model": "claude-sonnet-5",
          "rubric_grounded": true,
          "rubric_source": "personal",
          "steps": [{
            "title": "Compare the evidence",
            "guidance": "Use both sources.",
            "estimated_minutes": 35,
            "rubric_criterion_code": "C",
            "tool_need": "compare"
          }]
        }
        """#

        let result = try JSONDecoder().decode(PlanService.Result.self, from: Data(json.utf8))
        let step = try #require(result.steps.first)

        #expect(result.assignmentID == assignmentID)
        #expect(result.model == "claude-sonnet-5")
        #expect(result.rubricGrounded)
        #expect(result.rubricSource == "personal")
        #expect(step.title == "Compare the evidence")
        #expect(step.guidance == "Use both sources.")
        #expect(step.estimatedMinutes == 35)
        #expect(step.criterionCode == "C")
        #expect(step.toolNeed == "compare")
    }

    /// Generic planning legitimately has neither a rubric source nor a tool
    /// need. Missing optional fields must remain nil rather than making an
    /// otherwise valid plan undecodable.
    @Test("a generic plan accepts absent optional context")
    func genericResultDecodes() throws {
        let json = #"""
        {
          "assignment_id": "D982B7D0-A88B-4437-91A7-B475E8889AF0",
          "model": "claude-sonnet-5",
          "rubric_grounded": false,
          "steps": [{
            "title": "Make a first draft",
            "guidance": "Get the argument down.",
            "estimated_minutes": 45
          }]
        }
        """#

        let result = try JSONDecoder().decode(PlanService.Result.self, from: Data(json.utf8))
        let step = try #require(result.steps.first)

        #expect(result.rubricGrounded == false)
        #expect(result.rubricSource == nil)
        #expect(step.criterionCode == nil)
        #expect(step.toolNeed == nil)
    }

    /// A missing transport cannot enforce quota or create a plan, so it must
    /// fail closed before any request is attempted.
    @Test("no backend client fails closed")
    func missingClientFailsClosed() async {
        do {
            _ = try await PlanService(client: nil).breakdown(
                title: "History essay",
                taskType: "Essay",
                deadline: .now.addingTimeInterval(86_400),
                estimatedMinutes: 120
            )
            Issue.record("Planning unexpectedly succeeded without a backend client")
        } catch let failure as PlanService.Failure {
            #expect(failure == .unavailable)
        } catch {
            Issue.record("Planning returned an unexpected error: \(error)")
        }
    }
}
