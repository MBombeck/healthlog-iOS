// Phase 07 Wave 2 — the Spezi sample-collection cutover.
//
// The `SpeziAnchorStoring` seam and its `LocalStorage`-backed conformance are
// gone with the collectors they served: no production path writes into
// SpeziHealthKit's `queryAnchors` slots any more, and one that did would be
// writing an installation-global cursor, which is the exact shape this phase
// exists to retire. The slot name survives here as a *quarantine reference*
// only — a string an operator can trace, guarded by `SpeziAnchorPrefixCanaryTests`.
#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    import SpeziHealthKit

    /// Phase 07 Wave 2 — the account cutover away from installation-global
    /// sample cursors.
    ///
    /// Before this phase the app's per-sample cursor lived in two installation
    /// -global shapes: SpeziHealthKit's own `queryAnchors` slots, and (before
    /// v0.5.5) `hl.healthkit.anchor.<token>.<typeID>`. On a shared device both
    /// mean the same thing — account B resumes wherever account A stopped, and
    /// A's un-uploaded window is consumed by someone else's session.
    ///
    /// The migration this type now performs has exactly one shape per
    /// server-bound type, and it is the fail-closed one:
    ///
    ///   * The installation-global Spezi slot is **quarantined**. It is recorded
    ///     as a reference on the owner's partition, never read into it, and never
    ///     deleted. `DurableHealthCursorStore` exposes no API that promotes a
    ///     quarantined value into a partition, so no rollback and no future
    ///     refactor can turn it back into somebody's resume token.
    ///   * The partition then reports ``HealthSyncCursorMigrationState``
    ///     `.replayingLegacy`, which permits collection — from the 7/30/90/365-day
    ///     cutoff the authenticated user chose during onboarding, not from the
    ///     global anchor. The server folds the replay on `externalId`.
    ///
    /// The quarantine reference names a SpeziLocalStorage slot rather than a
    /// `UserDefaults` key, so `quarantinedLegacyValue(for:)` will not return its
    /// bytes. That is deliberate and harmless: the reference exists so an operator
    /// can *trace* the value the account never adopted, and the value itself stays
    /// exactly where SpeziHealthKit wrote it.
    ///
    /// **What was removed.** `migrateLegacyAnchorsIfNeeded` used to seed Spezi's
    /// global slots from the pre-v0.5.5 per-user blobs. That migration ran
    /// one-shot on every install years ago, and its direction — per-account value
    /// *into* an installation-global slot — is precisely the hazard this phase
    /// closes. It is gone; its one-shot flags and the legacy blobs are left on
    /// disk untouched.
    enum SpeziAnchorMigrator {
        /// The installation-global slot SpeziHealthKit persists a per-type anchor
        /// in. The formula is not part of any public SpeziHealthKit API, so it is
        /// pinned by `SpeziAnchorPrefixCanaryTests` against both the upstream
        /// constant and `SampleType.id`.
        static func speziGlobalAnchorKey(for typeIdentifier: String) -> String {
            "edu.stanford.Spezi.SpeziHealthKit.queryAnchors.\(typeIdentifier)"
        }

        /// Establishes the migration state for every server-bound sample type of
        /// one account, quarantining the installation-global anchor behind each.
        ///
        /// Idempotent by construction rather than by flag: the store refuses to
        /// re-run a migration for a partition that is already verified or already
        /// replaying, so a second cold launch is a no-op and a migration can never
        /// be repeated into a second adoption.
        ///
        /// A type whose key cannot be built (a blank owner) or whose migration the
        /// store refuses (the lease no longer owns the partition) is reported
        /// `.failed`, which forbids collection. There is no fallback.
        @discardableResult
        static func migrateAccountCursors(
            types: [String] = HealthLogSampleTypeRegistry.knownIdentifiers.sorted(),
            store: DurableHealthCursorStore,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> [String: HealthSyncCursorMigrationState] {
            var states: [String: HealthSyncCursorMigrationState] = [:]
            for typeIdentifier in types {
                guard let key = lease.cursorKey(typeIdentifier: typeIdentifier) else {
                    states[typeIdentifier] = .failed(reason: "cursor key could not be built")
                    continue
                }
                do {
                    states[typeIdentifier] = try await store.migrate(
                        key,
                        legacyKey: speziGlobalAnchorKey(for: typeIdentifier),
                        ownership: .unownedGlobal,
                        requiring: lease
                    )
                } catch {
                    states[typeIdentifier] = .failed(reason: "migration was refused")
                }
            }
            let collecting = states.values.filter(\.permitsCollection).count
            // Counts only: no identifier, no owner, no anchor.
            HLLog.healthKit
                .info(
                    "health cursor migration: \(collecting, privacy: .public) of \(states.count, privacy: .public) partitions may collect"
                )
            return states
        }

        /// Fail-closed rollback.
        ///
        /// Stops every server-bound partition of this account. It preserves the
        /// owner's own committed cursors and every quarantine reference, deletes
        /// nothing, and — because it only ever writes a `failed` migration record
        /// — cannot re-enable a collector or widen collection in any direction.
        /// Recovery is a fixed forward version, never a re-adoption of the global
        /// anchors this cutover quarantined.
        static func failClosed(
            reason: String,
            types: [String] = HealthLogSampleTypeRegistry.knownIdentifiers.sorted(),
            store: DurableHealthCursorStore,
            requiring lease: HealthSyncAuthenticatedLease
        ) async {
            for typeIdentifier in types {
                guard let key = lease.cursorKey(typeIdentifier: typeIdentifier) else { continue }
                await store.failClosed(key, reason: reason)
            }
        }
    }
#endif
