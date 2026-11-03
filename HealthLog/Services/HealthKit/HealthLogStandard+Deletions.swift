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

        /// The `HealthKitConstraint` witness. Nothing calls it: since Phase 07
        /// no `CollectSamples` is registered, and the app-owned collector hands
        /// a page's deletions to ``consumeDeletions(_:ofType:requiring:)``
        /// instead (A5). Until 1.4 this read our external UUID out of the
        /// deleted object's metadata, which HealthKit does not keep (only the
        /// sync identifier and version survive a deletion), so it could not
        /// have propagated anything even when it was still called.
        func handleDeletedObjects<Sample>(
            _: some Collection<HKDeletedObject> & Sendable,
            ofType _: SampleType<Sample>
        ) async {}
    }

    /// **A5 (1.4, R3 S4)** — the deletions of an anchored page, forwarded by
    /// ``HealthSampleDeletionForwarder`` through the attached reconciler, and
    /// kept in the same durable queue as an unaccepted page when they cannot go
    /// out.
    ///
    /// **A6 (1.4)** — a deleted HealthLog copy keeps its server row (that is
    /// the rule: deleting a copy in Apple Health deletes nothing on the
    /// server). Its server id goes into the owner's mirror tombstones, so the
    /// server mirror does not write the reading back, and it is not forwarded.
    extension HealthLogStandard: HealthSampleDeletionConsuming {
        func consumeDeletions(
            _ externalIDs: [String],
            copiesOf serverIDs: [String],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason? {
            if !serverIDs.isEmpty {
                if let refusal = lease.refusal { return refusal.holdReason }
                HealthKitMirrorTombstones(ownerID: lease.ownerID).record(serverIDs)
            }
            return await HealthSampleDeletionForwarder(server: deletionReconciler, queue: retryQueue)
                .forward(externalIDs, ofType: typeIdentifier, requiring: lease)
        }
    }
#endif
