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
    /// `user_id` is set from the verified session rather than passed in, and RLS
    /// would reject anything else regardless — the row cannot be attributed to
    /// another student even if this code were wrong.
    func createCourse(displayName: String, colorKey: String) async -> UUID? {
        guard let client, let userID = currentUserID(client) else { return nil }

        struct NewCourse: Encodable {
            let user_id: String
            let display_name: String
            let color_key: String
        }
        struct Created: Decodable { let id: UUID }

        do {
            let created: Created = try await client.from("courses")
                .insert(NewCourse(user_id: userID.uuidString.lowercased(),
                                  display_name: displayName,
                                  color_key: colorKey))
                .select("id")
                .single()
                .execute()
                .value
            return created.id
        } catch {
            print("[Albus] course sync failed: \(error)")
            return nil
        }
    }

    private func currentUserID(_ client: SupabaseClient) -> UUID? {
        client.auth.currentUser?.id
    }
}
