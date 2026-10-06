#if canImport(HealthKit)
    import Foundation

    // INT-A (#115 / 0.3) — an unexplained whole-batch 4xx may hold one event
    // type's anchor only for a bounded run of sweeps (see
    // `HealthKitBatchRejection.page(for:requiring:heldSweeps:)`).

    extension HeartHealthEventImporter {
        /// Consecutive sweeps an unexplained whole-batch 4xx held this page's
        /// type. One type per page: every sweep reads a single category type.
        func heldRejectionKey(_ entries: [HealthKitBatchEntryDTO]) -> String {
            "hl.hkevent.heldRejections." + partitionToken + "." + (entries.first?.hkIdentifier ?? "none")
        }

        /// The page a whole-batch 4xx leaves, with the run of held sweeps
        /// counted per type: a held page extends the run, a page that moves on
        /// (stored or registered) ends it.
        func rejectedPage(
            _ rejection: HealthKitBatchRejection,
            entries: [HealthKitBatchEntryDTO],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            let key = heldRejectionKey(entries)
            let heldSweeps = defaults.integer(forKey: key) + 1
            let page = await rejection.page(for: entries, requiring: lease, heldSweeps: heldSweeps)
            if page.hasNonterminalEntry {
                defaults.set(heldSweeps, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            return page
        }
    }
#endif
