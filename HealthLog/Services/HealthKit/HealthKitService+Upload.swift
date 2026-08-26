import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// Outcome + uploader handoff (Spezi-side authoritative). Extracted from
    /// `HealthKitService.swift` (file_length discipline — pure move, no
    /// behaviour change).
    extension HealthKitService {
        // MARK: - Outcome + Uploader handoff (Spezi-side authoritative)

        /// Outcome eines `uploadAndDecide`-Calls. Steuert ob der Caller den
        /// neuen `HKQueryAnchor` persistieren darf (`.consumed`) oder ob er
        /// den alten Anchor stehen lassen muss (`.keepAnchor`). Policy
        /// (A1-Audit H6 + W2c-A1H Impl-Report; W2 silent-data-loss-Fix):
        /// network errors keep the anchor; missing-uploader keeps it; empty
        /// batches advance. Bei 2xx mit Per-Entry-Status wird differenziert:
        /// `inserted | duplicate | skipped(value_out_of_range)` sind terminal
        /// → advance; `skipped(unmappable_identifier)` ist TRANSIENT (Server
        /// kennt den Typ noch nicht) → `.keepAnchor`, damit das Sample nach
        /// dem Server-Cutover re-synct statt still verloren zu gehen.
        /// Partial-success edge: a chunk-N+1 throw after chunk-N 2xx leaves
        /// the anchor stale → next wake re-delivers; the server deduplicates
        /// via `externalId`.
        ///
        /// Post-W-A5 `HealthLogStandard.handleNewSamples` (the Spezi-side
        /// authoritative receiver) calls `uploadAndDecide(...)` and
        /// branches on the result to mirror the same anchor-after-200
        /// semantics for the Spezi-side anchor store.
        enum SampleConsumeOutcome: Equatable {
            /// Der Caller darf den neuen `HKQueryAnchor` persistieren — alle Entries
            /// sind beim Server gelandet (oder es gab nichts zu uploaden).
            case consumed
            /// Der Caller MUSS den alten Anchor stehen lassen — Network/Server-Fehler
            /// hat verhindert, dass der Server den Batch sieht.
            case keepAnchor
        }

        /// Shared upload-and-decide path consumed by
        /// `HealthLogStandard.handleNewSamples` (the Spezi-side
        /// authoritative receiver). Centralises the anchor-after-200
        /// policy so the per-cluster Spezi path inherits bit-for-bit
        /// identical idempotency / chunking / skip-reason logging
        /// behaviour the legacy `handleNewSamples` carried.
        ///
        /// **Garantie:** Returnt `.consumed` ⟺ jeder Chunk wurde mit 2xx
        /// beantwortet UND kein Per-Entry-Status war `skipped(unmappable_-
        /// identifier)`. Returnt `.keepAnchor` sobald (a) irgendein Chunk im
        /// Throw landet (Network/Server-Fehler) ODER (b) der Server einen
        /// Eintrag mit `unmappable_identifier` skippt — in beiden Fällen
        /// bleibt der Anchor stehen, der nächste Wakeup re-fetched alles seit
        /// dem alten Anchor. `skipped(value_out_of_range)` bleibt terminal
        /// (advance), sonst loopte ein einzelnes bogus-Sample endlos.
        static func uploadAndDecide(
            entries: [HealthKitBatchEntryDTO],
            uploader: MeasurementBatchUploader,
            typeIdentifier: String,
            authenticationLease: MeasurementUploadAuthenticationLease? = nil
        ) async -> SampleConsumeOutcome {
            do {
                let outcomes = if let authenticationLease {
                    try await uploader.upload(entries, requiring: authenticationLease)
                } else {
                    try await uploader.upload(entries)
                }
                let totalConsumed = outcomes.reduce(0) { $0 + $1.consumedIndexes.count }
                let totalSkipped = outcomes.reduce(0) { $0 + $1.skipped.count }
                // `skipped`-Reasons für Triage loggen + nach Retriability
                // klassifizieren. Der Server quittiert mit HTTP 200 + Per-Entry
                // `skipped`, unterscheidet aber zwei Reasons (siehe
                // `src/app/api/measurements/batch/route.ts:200-220`):
                //
                // - `unmappable_identifier` — der Server-Mapper kennt den HK-
                //   Identifier (noch) nicht (die sechs `HK_QUANTITY_TYPE_-
                //   DEFERRED`-Typen). TRANSIENT: wird gültig, sobald der Server
                //   das Mapping nachzieht. Würden wir hier `.consumed` melden,
                //   schöbe der Caller den HK-Anchor vor → das Sample ginge
                //   **dauerhaft + still** verloren (W2 silent-data-loss-Bug).
                //   Also `.keepAnchor`, damit dieselben Samples beim nächsten
                //   Wakeup bzw. nach dem Server-Cutover erneut hochgeladen
                //   werden. Server dedupliziert via `externalId`, der Re-Upload
                //   ist also safe + low-volume.
                // - `value_out_of_range` — der Wert liegt außerhalb der
                //   Plausibilitäts-Range. TERMINAL: ein Retry änderte am Status
                //   nichts; den Anchor stehen zu lassen ergäbe eine Endlos-
                //   Schleife für genau dieses Sample. Also weiterhin advance.
                var hasUnmappableSkip = false
                for outcome in outcomes {
                    for skipped in outcome.skipped {
                        HLLog.healthKit
                            .info("HK-Upload skipped index=\(skipped.index, privacy: .public) reason=\(skipped.reason, privacy: .public)")
                        if skipped.reason == HealthKitServerSupportConfig.reasonUnmappableIdentifier {
                            hasUnmappableSkip = true
                        }
                    }
                }
                if hasUnmappableSkip {
                    HLLog.healthKit
                        .info(
                            "HK-Upload \(typeIdentifier, privacy: .public): unmappable_identifier-Skip — Anchor bleibt stehen (\(totalConsumed, privacy: .public) consumed)."
                        )
                    return .keepAnchor
                }
                HLLog.healthKit
                    .info(
                        "HK-Upload \(typeIdentifier, privacy: .public): \(totalConsumed, privacy: .public) consumed (\(totalSkipped, privacy: .public) skipped)"
                    )
                return .consumed
            } catch {
                // Network/Server-Fehler — Anchor stehen lassen, damit beim nächsten
                // Observer-Wakeup oder BG-Sweep dieselben Samples wieder durchkommen.
                // Server dedupliziert via externalId, also ist der Re-Upload safe.
                // Non-retriable-Fehler (z. B. 4xx Schema-Drift) würden im Worst-Case
                // dieselbe Stelle blockieren; das ist beabsichtigt — lieber einen
                // sichtbaren Server-Fehler-Loop als stille Daten-Verluste.
                HLLog.healthKit
                    .error(
                        "HK-Upload \(typeIdentifier, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public) — Anchor bleibt stehen."
                    )
                return .keepAnchor
            }
        }
    }

#endif
