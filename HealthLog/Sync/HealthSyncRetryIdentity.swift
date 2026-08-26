import CryptoKit
import Foundation

// Phase 07 — the retry identity every durable HealthLog write shares.
//
// Split out of `HealthSyncContracts.swift` by plan 07-05. `MoodRepository`
// derives both a mood entry's optimistic local id and its idempotency key from
// this envelope, and the repositories compile into the widget extension as well
// as the app — while the rest of the Phase-07 vocabulary (leases, cursor keys,
// commit policy) is HealthKit-layer and stays where Wave 0 put it.
//
// Nothing behavioural changed in the move: both types are byte-identical to the
// Wave-0 definitions, and the Wave-0 suites that assert on them are untouched.

/// One collecting subsystem. Part of every cursor key, retry envelope, and
/// diagnostic record, so no two importers can share a cursor namespace.
enum HealthSyncSource: String, CaseIterable, Sendable, Codable {
    case speziSamples
    case workout
    case ecg
    case dailyStatistics
    case heartRateBucket
    case nutrient
    case mood
    case appleMedication
    case cycle
    case heartEvent
    case outbox
}

// MARK: - Stable retry identity

/// Owner-bound, restart-stable identity for one durable retry operation.
///
/// The idempotency key is *derived*, never minted: a relaunch that rebuilds the
/// same envelope produces the same key, so the server's replay window
/// deduplicates instead of double-writing.
struct HealthSyncRetryEnvelope: Hashable, Sendable {
    let ownerID: String
    let source: HealthSyncSource
    /// The externally stable identity of the payload — a HealthKit sample UUID
    /// or a `stats:<type>:<day>` external id. Never a timestamp or a name hash.
    let stableIdentity: String

    init?(ownerID: String, source: HealthSyncSource, stableIdentity: String) {
        let owner = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = stableIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !identity.isEmpty else { return nil }
        self.ownerID = owner
        self.source = source
        self.stableIdentity = identity
    }

    var operationKey: String {
        "\(source.rawValue)|\(ownerID)|\(stableIdentity)"
    }

    /// Deterministic UUID-shaped idempotency key derived from `operationKey`.
    var idempotencyKey: String {
        let digest = SHA256.hash(data: Data(operationKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let groups = [0 ..< 8, 8 ..< 12, 12 ..< 16, 16 ..< 20, 20 ..< 32]
        return groups
            .map { range in String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound) ..<
                    hex.index(hex.startIndex, offsetBy: range.upperBound)])
            }
            .joined(separator: "-")
    }
}
