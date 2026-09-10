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

    /// Creates a subject server-side and returns its id.
    ///
    /// Through an RPC rather than a plain insert. The template and level
    /// arguments are sent as null: the RPC still declares them, because it
    /// belongs to a migration that has not been deployed yet and changing its
    /// signature would change what production is waiting to receive.
    ///
    /// `user_id` is set from the verified session inside the function rather
    /// than passed in, and RLS would reject anything else regardless — the row
    /// cannot be attributed to another student even if this code were wrong.
    func createCourse(displayName: String, colorKey: String,
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
                               p_template_code: nil,
                               p_level: nil,
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
                      targetGrade: Int? = nil,
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
                               p_level: nil,
                               p_target_grade: targetGrade,
                               p_clear_level: false,
                               p_clear_target_grade: clearTargetGrade)
            )
            .execute()
            .value
        } catch {
            print("[Albus] course update failed: \(error)")
            return false
        }
    }

}
