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
                      curriculumSubjectCode: String? = nil) async -> UUID? {
        guard let client else { return nil }

        struct Params: Encodable {
            let p_display_name: String
            let p_color_key: String
            let p_template_code: String?
        }

        do {
            return try await client.rpc(
                "create_course",
                params: Params(p_display_name: displayName,
                               p_color_key: colorKey,
                               p_template_code: curriculumSubjectCode)
            )
            .execute()
            .value
        } catch {
            print("[Albus] course sync failed: \(error)")
            return nil
        }
    }

    private func currentUserID(_ client: SupabaseClient) -> UUID? {
        client.auth.currentUser?.id
    }
}
