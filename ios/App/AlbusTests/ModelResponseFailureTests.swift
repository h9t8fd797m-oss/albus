import Foundation
import Supabase
import Testing
@testable import Albus

@Suite("Unusable model responses")
struct ModelResponseFailureTests {

    private func serverError(_ code: String) -> FunctionsError {
        let body = try! JSONSerialization.data(withJSONObject: ["error": code])
        return .httpError(code: 502, data: body)
    }

    @Test("empty and malformed answers are retryable in every AI service")
    func retryableMappings() {
        for code in ["EMPTY_RESPONSE", "MALFORMED_RESPONSE"] {
            let error = serverError(code)
            #expect(PlanService.translate(error) == .unusableResponse)
            #expect(GradingService.translate(error) == .unusableResponse)
            #expect(ChatService.translate(error) == .unusableResponse)
        }
    }

    @Test("the three services describe the same failure once")
    func sharedCopy() {
        let descriptions = [
            PlanService.Failure.unusableResponse.errorDescription,
            GradingService.Failure.unusableResponse.errorDescription,
            ChatService.Failure.unusableResponse.errorDescription,
        ].compactMap { $0 }

        #expect(descriptions.count == 3)
        #expect(Set(descriptions).count == 1)
        #expect(descriptions.first == ModelResponseFailure.retryableDescription)
    }

    @Test("a truncated grading remains a distinct non-retryable instruction")
    func truncationStaysSeparate() {
        let failure = GradingService.translate(serverError("RESPONSE_TRUNCATED"))

        #expect(failure == .tooLongToMark)
        #expect(failure != .unusableResponse)
    }
}
