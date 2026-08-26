// swiftformat:disable opaqueGenericParameters
// `Sample` stays a named generic (referenced by `SampleType<Sample>`), mirroring
// the main `HealthLogStandard` file.

// A360-5 M-1 — HK→server delete propagation, split out of HealthLogStandard.swift
// to keep that file under the 600-line file_length budget (PROJECT_GUIDE.md discipline).

#if canImport(SpeziHealthKit)
    import HealthKit
    import SpeziHealthKit

    extension HealthLogStandard {
        /// Setter-injection for the server-deletion reconciler (A360-5 M-1).
        /// Kept separate from ``attachUploader`` so the composition root can
        /// thread the `MeasurementsRepository` (which already conforms to
        /// `MeasurementDeletionReconciler`) without widening the uploader-attach
        /// signature. Idempotent — re-calling overwrites the reference; tests
        /// detach by passing nil.
        func attachDeletionReconciler(_ reconciler: (any MeasurementDeletionReconciler)?) {
            deletionReconciler = reconciler
        }

        /// Notifies the standard about a batch of deleted HealthKit objects.
        ///
        /// **A360-5 M-1 — close the HK→server delete triangle.** Previously a
        /// no-op, so a measurement the user deleted in Apple Health stayed on
        /// the HealthLog server forever (one-way mirror → orphaned rows). We now
        /// extract each deleted sample's `HKMetadataKeyExternalUUID` (the id our
        /// own writes stamp, and the externalId the server dedups on) and
        /// forward the set to the injected `MeasurementDeletionReconciler`, which
        /// issues `DELETE /api/measurements/by-external-ids` (idempotent — a
        /// replay on an already-deleted set is a server-side no-op).
        ///
        /// **BH-final-diff H2 — ownership-confirmed deletions only.** A foreign
        /// app can set a colliding `HKMetadataKeyExternalUUID`; deleting that
        /// foreign sample must NOT delete our server row. The read/anti-echo path
        /// confirms ownership with two signals (externalUUID present AND author ==
        /// `HKSource.default()`), but `HKDeletedObject` exposes only `uuid` +
        /// `metadata` — never `sourceRevision`. We therefore stamp every HealthLog
        /// write with an app-private origin marker
        /// (``HealthKitSampleOwnership/appOriginMetadataKey``, preserved in the
        /// deletion's metadata) and propagate a deletion ONLY when that marker
        /// AND the external UUID are both present. Anything we cannot confirm as
        /// ours is dropped (safe: an orphaned server row converges on the next
        /// full reconcile / list-load — silent over-deletion is the worse hazard).
        ///
        /// A nil reconciler (pre-attach / tests) keeps the old no-op behaviour.
        /// Failures are logged, not thrown: a transient network error must not
        /// crash the collector.
        func handleDeletedObjects<Sample>(
            _ deletedObjects: some Collection<HKDeletedObject> & Sendable,
            ofType sampleType: SampleType<Sample>
        ) async {
            guard !deletedObjects.isEmpty else { return }
            let identifier = sampleType.hkSampleType.identifier
            let externalIDs: [String] = deletedObjects.compactMap { deleted in
                guard HealthKitSampleOwnership.isAppMintedDeletion(metadata: deleted.metadata) else {
                    return nil
                }
                return deleted.metadata?[HKMetadataKeyExternalUUID] as? String
            }
            guard !externalIDs.isEmpty else {
                HLLog.healthKit
                    .debug(
                        "Spezi HK \(identifier, privacy: .public) deletion batch \(deletedObjects.count, privacy: .public) — no app-minted (origin-marked) externalUUID linkage, skipped"
                    )
                return
            }
            guard let deletionReconciler else {
                HLLog.healthKit
                    .debug(
                        "Spezi HK \(identifier, privacy: .public) deletion batch \(externalIDs.count, privacy: .public) — reconciler unwired, skipped"
                    )
                return
            }
            do {
                try await deletionReconciler.reconcileDeletedExternalIDs(externalIDs)
                HLLog.healthKit
                    .info(
                        "Spezi HK \(identifier, privacy: .public) deletion batch \(externalIDs.count, privacy: .public) → server delete-by-external-id propagated"
                    )
            } catch {
                HLLog.healthKit
                    .warning(
                        "Spezi HK \(identifier, privacy: .public) deletion propagation failed (will converge on next reconcile): \(error.localizedDescription, privacy: .public)"
                    )
            }
        }
    }
#endif
