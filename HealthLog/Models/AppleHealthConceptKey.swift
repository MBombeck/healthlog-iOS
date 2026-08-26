import CryptoKit
import Foundation

/// **CU-10 / GH #47 — the stable identity of an Apple Health medication concept.**
///
/// The mirror's server upsert key is `(userId, externalSource, externalId)`, so
/// the whole feature rests on `externalId` being the SAME string for the same
/// Health-app medication on every process run. Until v1.34 the reader derived it
/// with `String(describing: HKHealthConceptIdentifier)`. That type is opaque and
/// documents no `description` contract, so it fell back to `NSObject`'s default —
/// `<HKHealthConceptIdentifier: 0x12568db80>`, a per-allocation MEMORY ADDRESS.
/// Every sweep minted a fresh medication row (23 phantom rows on the operator's
/// live instance in a single day) and every dose event resolved through the same
/// rotating string, so no dose ever found its medication.
///
/// What Apple *does* document for that type is `NSSecureCoding`. So the identity
/// is taken from the archived bytes (`NSKeyedArchiver`, `requiringSecureCoding:
/// true`) and hashed into a 64-char SHA-256 hex digest — deterministic across
/// process runs, well inside the server's 128-char `externalId` cap, and a shape
/// the server's stability guard accepts (no `0x` prefix, no angle brackets).
///
/// **The HealthKit-free seam.** `HKHealthConceptIdentifier` cannot be constructed
/// in a unit test, so the hashing half lives here, over plain `Data`. The reader
/// contributes only the archiving call; ``derive(fromArchivedIdentifier:)`` is
/// what the determinism tests pin.
public enum AppleHealthConceptKey {
    /// Bumped whenever ``derive(fromArchivedIdentifier:)`` changes shape. The
    /// mirror registry stamps this alongside its concept map and discards the
    /// map when the stamp is missing or older (see
    /// ``AppleHealthMirrorRegistry``), so keys minted under an earlier — here:
    /// pointer-shaped — scheme never linger.
    ///
    /// - 1: `String(describing:)` (unstable, the defect).
    /// - 2: SHA-256 hex over the securely-archived identifier.
    public static let schemaVersion = 2

    /// Deterministic 64-char lowercase SHA-256 hex over the securely-archived
    /// concept identifier. Same bytes in → same key out, in this process run and
    /// every later one.
    public static func derive(fromArchivedIdentifier data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `value` has the shape ``derive(fromArchivedIdentifier:)`` mints.
    /// The registry migration keeps only entries that satisfy this, which is what
    /// drops the poisoned `<HKHealthConceptIdentifier: 0x…>` keys.
    public static func isDerivedKey(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }
}

/// **Server v1.32.37 — the identifier shapes that cannot be a stable identity.**
///
/// Mirrors `src/lib/validations/external-id.ts` on the server, which refuses
/// these on every ingest surface: the single routes with a hard `422` naming
/// `externalId`, the batch/bulk routes with a per-entry `skipped` +
/// `reason: "unstable_external_id"` while the rest of the batch lands.
///
/// The client keeps its own copy of the rule because it is the party that knows
/// what it is about to send: a pre-flight refusal names the real problem, while
/// the server's `422` arrives as an untyped "Validation failed" envelope whose
/// `details.issues[].path` the transport layer does not surface.
public enum UnstableExternalIDShape: String, Sendable, Equatable, CaseIterable {
    /// Empty or whitespace-only — carries no identity by construction.
    case blank
    /// A bare `0x…` hex value: a raw address, valid only inside the process that
    /// printed it.
    case pointerAddress = "pointer_address"
    /// An angle-bracketed default object description carrying a hex pointer,
    /// e.g. `<HKHealthConceptIdentifier: 0x12568db80>` — the exact shape that
    /// minted the phantom rows.
    case objectDescription = "object_description"
}

public extension AppleHealthConceptKey {
    /// The per-entry `reason` every batch/bulk surface reports for a refused
    /// identifier (server `UNSTABLE_EXTERNAL_ID_REASON`).
    static let unstableExternalIDReason = "unstable_external_id"

    /// Classify an external identifier. `nil` = usable as an identity.
    ///
    /// Deliberately narrow, exactly like the server rule: the cost of a false
    /// negative is a duplicate row, the cost of a false positive is a client that
    /// can no longer sync at all. UUIDs, structured prefixes and hex digests all
    /// pass.
    static func classify(_ value: String) -> UnstableExternalIDShape? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .blank }
        if isBarePointer(trimmed) { return .pointerAddress }
        if containsPointerDescription(trimmed) { return .objectDescription }
        return nil
    }

    // MARK: - Rule internals

    /// `^0x[0-9a-f]+$`, anchored both ends so a vendor id that merely *contains*
    /// `0x` is untouched.
    private static func isBarePointer(_ value: String) -> Bool {
        let body = value.dropFirst(2)
        guard value.count > 2, value.prefix(2).lowercased() == "0x", !body.isEmpty else { return false }
        return body.allSatisfy(\.isHexDigit)
    }

    /// `<[^<>]*0x[0-9a-f]+[^<>]*>` — one bracket pair with no nested bracket,
    /// carrying a hex-pointer token. Scanned anywhere in the value so a client
    /// that prefixes its own namespace (`apple:<Foo: 0x1234>`) is caught too.
    private static func containsPointerDescription(_ value: String) -> Bool {
        let chars = Array(value)
        var index = 0
        while index < chars.count {
            guard chars[index] == "<" else {
                index += 1
                continue
            }
            var end = index + 1
            while end < chars.count, chars[end] != ">", chars[end] != "<" {
                end += 1
            }
            guard end < chars.count, chars[end] == ">" else {
                index = end
                continue
            }
            if containsHexPointerToken(chars[(index + 1) ..< end]) { return true }
            index = end + 1
        }
        return false
    }

    /// A `0x` followed by at least one hex digit, anywhere in the slice.
    private static func containsHexPointerToken(_ chars: ArraySlice<Character>) -> Bool {
        let flat = Array(chars)
        guard flat.count >= 3 else { return false }
        for start in 0 ... (flat.count - 3) where flat[start] == "0"
            && (flat[start + 1] == "x" || flat[start + 1] == "X")
            && flat[start + 2].isHexDigit
        {
            return true
        }
        return false
    }
}
