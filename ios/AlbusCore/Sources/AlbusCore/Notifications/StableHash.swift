import Foundation

/// A hash that means the same thing tomorrow.
///
/// **Swift's own `hashValue` cannot be used for any of this.** `Hashable` is
/// seeded with a per-process random value, so `"brief".hashValue` differs
/// between launches. A copy picker keyed on it looks deterministic in a single
/// test run and silently picks a different line every time the app starts —
/// which makes the no-repeat window useless and is close to impossible to
/// reproduce deliberately. Everything that has to survive a relaunch, or be
/// pinned by a test, goes through here instead.
///
/// FNV-1a over bytes, finished through SplitMix64 so that inputs differing in
/// one byte do not produce neighbouring outputs — the picker takes a modulus,
/// and a hash with poor low-bit dispersion would bias which lines are reachable.
public enum StableHash {

    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x1000_0000_01b3

    public static func bytes<S: Sequence>(_ input: S) -> UInt64 where S.Element == UInt8 {
        var hash = offsetBasis
        for byte in input {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return mix(hash)
    }

    public static func value(_ input: String) -> UInt64 {
        bytes(Array(input.utf8))
    }

    public static func value(_ uuid: UUID, _ salt: String) -> UInt64 {
        let u = uuid.uuid
        var buffer: [UInt8] = [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
        ]
        buffer.append(contentsOf: Array(salt.utf8))
        return bytes(buffer)
    }

    /// A short printable digest, for fingerprints and signatures.
    public static func string(_ input: String) -> String {
        String(value(input), radix: 36)
    }

    /// Order-independent digest of a set of ids.
    ///
    /// Sorted before hashing because the caller's set has no order and two
    /// runs must agree, or every rebuild would look like a change.
    public static func signature(_ ids: some Sequence<UUID>) -> String {
        let sorted = ids.map(\.uuidString).sorted()
        return sorted.isEmpty ? "" : string(sorted.joined(separator: ","))
    }

    /// SplitMix64's finaliser. Cheap, and well-tested at spreading bits.
    private static func mix(_ input: UInt64) -> UInt64 {
        var z = input &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
