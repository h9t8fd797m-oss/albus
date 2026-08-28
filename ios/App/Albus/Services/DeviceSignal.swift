import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The one identifier Albus sends about the device, and the reasoning for it.
///
/// **What this is.** `identifierForVendor`: an id iOS gives us that is stable
/// for this device *and this vendor*, resets when the student deletes every
/// Albus app, and is not a hardware serial. It is the weakest identifier that
/// can answer the only question we ask of it — "has this device signed up five
/// times this afternoon" — which is what makes it the right one to pick.
///
/// **What it is not.** Not advertising identity, not a fingerprint, not
/// anything assembled from device characteristics. Nothing here is combined
/// with anything else, and no permission is requested because none is needed.
///
/// **What the server does with it.** Hashes it with a secret it holds and we do
/// not, stores the digest, and throws the value away. The database never holds
/// this string. See `supabase/functions/_shared/signals.ts`.
///
/// **What happens without it.** The header is absent and everything works. The
/// risk model treats a missing signal as no signal, and no single signal can
/// escalate an account on its own — so withholding it costs a student nothing,
/// and sending it costs them nothing either.
enum DeviceSignal {

    /// The header the Edge Functions read. Nil when iOS declines to answer,
    /// which it legitimately does — briefly after a restart, before the device
    /// is first unlocked.
    static var headerValue: String? {
        #if canImport(UIKit)
        UIDevice.current.identifierForVendor?.uuidString
        #else
        nil
        #endif
    }

    static let headerName = "x-albus-device"

    /// Merged into a function invocation's headers. Returns the caller's own
    /// headers untouched when there is nothing to add, so a call site never has
    /// to branch on availability.
    static func headers(adding existing: [String: String] = [:]) -> [String: String] {
        guard let headerValue else { return existing }
        var merged = existing
        merged[headerName] = headerValue
        return merged
    }
}
