import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// Anchor key utilities (logout sweep + migrator lookup). Extracted from
    /// `HealthKitService.swift` (file_length discipline — pure move, no
    /// behaviour change). All members are `static` / `nonisolated`, so the
    /// move does not touch actor isolation or visibility.
    public extension HealthKitService {
        // MARK: - Anchor key utilities (logout sweep + migrator lookup)

        //
        // The legacy per-User UserDefaults anchor keys remain on disk
        // (rollback safety per PB12; v0.5.6 will do a one-shot sweep).
        // SpeziLocalStorage owns the live anchor stream now via the
        // W-A3 anchor migrator handover.
        //
        // **Per-User Partitioning** (A1-Audit, Bonus-Section):
        // Key shape `hl.healthkit.anchor.<userId>.<typeID>`. Nach Logout/Re-Login mit
        // anderem Account würde sonst der vorige Anchor weiterleben — der User wäre
        // beim ersten Wakeup in einer Sample-Stream-Position für einen Account, dem er
        // gar nicht mehr gehört. Bei fehlendem User-ID (Tests, Pre-Login Reads) fällt
        // die Partition auf `_anonymous` zurück.

        static let anchorDefaultsKeyPrefix = "hl.healthkit.anchor."

        /// Wischt alle persistenten Anchors für einen User. Wird vom AuthStore beim
        /// Logout aufgerufen — ohne diesen Sweep würde ein Re-Login mit anderem
        /// Account die HK-Sample-Stream-Position des vorigen Users übernehmen.
        ///
        /// Public + nonisolated, damit der Logout-Pfad ohne `await` aufrufen kann.
        /// Der UserDefaults-Zugriff ist Apple-dokumentiert thread-safe.
        ///
        /// **Post-W-A5:** SpeziLocalStorage owns the live anchor stream;
        /// the legacy UserDefaults keys are read-only-historic but still
        /// wiped on logout to keep the rollback contract clean (a future
        /// roll-back from Spezi to the legacy observer pipeline would
        /// otherwise inherit the previous user's anchor cursor).
        nonisolated static func clearAnchors(
            for userId: String?,
            in defaults: UserDefaults = .standard
        ) {
            let prefix = anchorDefaultsKeyPrefix + Self.partitionToken(for: userId) + "."
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                defaults.removeObject(forKey: key)
            }
        }

        /// Partitions-Token aus dem Keychain-User-ID. Whitespace + Punkt-Stripping,
        /// damit der Key-Shape (`prefix.<token>.<typeID>`) eindeutig parse-bar bleibt.
        ///
        /// Consumed by `SpeziAnchorMigrator` (W-A3 anchor handover) and
        /// `HKReadinessStore` / `HealthKitBackfillWindowStore` for their
        /// own per-User partitioning logic.
        ///
        /// **M-6 hardening (v0.6.2):** legacy behaviour only stripped dots, so
        /// a user-id containing `/`, `..`, or unicode look-alikes would have
        /// survived into the UserDefaults key (`hl.healthkit.anchor.<token>.<type>`).
        /// We now apply a strict `[A-Za-z0-9_-]` allowlist + cap at 64 chars.
        /// Any character outside the allowlist is dropped (not replaced — see
        /// `HealthKitBackfillWindowStore.partitionToken` for the same rationale).
        /// Mirrored exactly with that store so the partition keys stay aligned.
        nonisolated static func partitionToken(for userId: String?) -> String {
            guard let raw = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return "_anonymous"
            }
            let filtered = raw.unicodeScalars.lazy.filter { scalar in
                (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                    || scalar.value == 0x5F // _
                    || scalar.value == 0x2D // -
            }
            let sanitized = String(String.UnicodeScalarView(filtered))
            guard !sanitized.isEmpty else { return "_anonymous" }
            return String(sanitized.prefix(64))
        }
    }

#endif
