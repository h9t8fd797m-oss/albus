import Foundation
import Supabase
import AlbusCore

/// The two things the server needs to know about the student: what they are
/// studying, and which subjects.
///
/// Both were collected and then kept on the device. Onboarding asked "IB or AP?"
/// and stored the answer in `UserDefaults`, where nothing could read it — so Ask
/// Albus answered "is this enough for HL?" without knowing whether the student
/// had ever heard of HL. Two short lines in a prompt change most of the answers
/// in this app, and they were three round trips away the whole time.
struct ProfileService {

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// Records which curriculum the student follows.
    ///
    /// Best-effort by design: a student whose profile did not sync still gets a
    /// working app, just slightly less specific answers. Failing onboarding over
    /// it would be the wrong trade.
    func syncCurriculum(_ code: String) async {
        guard let client else { return }
        do {
            try await client.from("profiles")
                .update(["curriculum_code": code])
                .eq("id", value: currentUserID(client)?.uuidString.lowercased() ?? "")
                .execute()
        } catch {
            print("[Albus] curriculum sync failed: \(error)")
        }
    }

    /// Creates a subject server-side and returns its id.
    ///
    /// Through an RPC rather than a plain insert, so the subject is linked to its
    /// specification in the same statement. `curriculumSubjectCode` is the
    /// bundled code (`IB_DP_HISTORY`); the server resolves it to a
    /// `course_templates` row, which is what lets Ask Albus know that this
    /// student's History IA is 25% at SL and marked out of 25.
    ///
    /// `user_id` is set from the verified session inside the function rather
    /// than passed in, and RLS would reject anything else regardless — the row
    /// cannot be attributed to another student even if this code were wrong.
    func createCourse(displayName: String, colorKey: String,
                      curriculumSubjectCode: String? = nil,
                      level: CourseLevel? = nil,
                      targetGrade: Int? = nil) async -> UUID? {
        guard let client else { return nil }

        struct Params: Encodable {
            let p_display_name: String
            let p_color_key: String
            let p_template_code: String?
            let p_level: String?
            let p_target_grade: Int?
        }

        do {
            return try await client.rpc(
                "create_course",
                params: Params(p_display_name: displayName,
                               p_color_key: colorKey,
                               p_template_code: curriculumSubjectCode,
                               p_level: level?.rawValue,
                               p_target_grade: targetGrade)
            )
            .execute()
            .value
        } catch {
            print("[Albus] course sync failed: \(error)")
            return nil
        }
    }

    /// Change a subject's level or target grade without deleting and re-adding
    /// it — moving from HL to SL in the first term is common, and the subject's
    /// assignments must survive it.
    ///
    /// `security invoker` on the server, so the owner policy on `courses` is
    /// what decides this is writable. Clearing is explicit rather than "pass
    /// nil": a partial update must not silently erase the field it omits.
    @discardableResult
    func updateCourse(remoteID: UUID,
                      level: CourseLevel? = nil,
                      targetGrade: Int? = nil,
                      clearLevel: Bool = false,
                      clearTargetGrade: Bool = false) async -> Bool {
        guard let client else { return false }

        struct Params: Encodable {
            let p_course_id: UUID
            let p_level: String?
            let p_target_grade: Int?
            let p_clear_level: Bool
            let p_clear_target_grade: Bool
        }

        do {
            return try await client.rpc(
                "update_course",
                params: Params(p_course_id: remoteID,
                               p_level: level?.rawValue,
                               p_target_grade: targetGrade,
                               p_clear_level: clearLevel,
                               p_clear_target_grade: clearTargetGrade)
            )
            .execute()
            .value
        } catch {
            print("[Albus] course update failed: \(error)")
            return false
        }
    }

    /// Record which examination session the student is sitting, and what they
    /// are aiming for overall.
    ///
    /// The session rather than the DP year, deliberately: "DP1" stops being
    /// true after twelve months and nothing would ever correct it. The server
    /// derives the year from this whenever it needs one.
    @discardableResult
    func setIBContext(examSession: ExamSession? = nil,
                      targetPoints: Int? = nil) async -> Bool {
        guard let client else { return false }

        struct Params: Encodable {
            let p_exam_session: String?
            let p_target_points: Int?
            let p_clear_exam_session: Bool
            let p_clear_target_points: Bool
        }

        do {
            return try await client.rpc(
                "set_ib_context",
                params: Params(p_exam_session: examSession?.rawValue,
                               p_target_points: targetPoints,
                               p_clear_exam_session: false,
                               p_clear_target_points: false)
            )
            .execute()
            .value
        } catch {
            print("[Albus] IB context sync failed: \(error)")
            return false
        }
    }

    private func currentUserID(_ client: SupabaseClient) -> UUID? {
        client.auth.currentUser?.id
    }
}
