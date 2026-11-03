#if canImport(HealthKit)
    import Foundation
    import HealthKit

    // A5 (1.4, R3 S4) — the deletions an anchored page reports.
    //
    // Since Phase 07 the app owns the anchored query, and until 1.4 it only
    // counted `deletedObjects`: the anchor moved past them, so a reading the
    // person deleted in Apple Health stayed on the server for good. Now a page's
    // deletions travel with it. They go to the server, or into the outbox when
    // they cannot, before the cursor may pass them; a deletion that is neither
    // sent nor kept holds the page, and the next read reports it again.
    //
    // Only the live leg forwards them. The backwards history walk reads with
    // `HKSampleQuery`, which never reports a deletion. The legacy leg of a 1.2.0
    // upgrade is anchored, but it reads inside a date window, and HealthKit
    // applies a query's predicate to deleted objects too, which carry no date;
    // the live leg reads without a predicate once it has caught up, so it sees
    // every deletion from then on.
    //
    // A6 (1.4) — a deleted HealthLog copy (its sync identifier names a server
    // row) is not forwarded: it was never uploaded. Its server id becomes a
    // tombstone instead, so the server mirror does not write the reading back.

    /// The deletion seam. A consumer that forwards deletions conforms; one that
    /// does not (test doubles of the sample half) is skipped, so a page without
    /// a forwarder behaves exactly as it did before 1.4.
    protocol HealthSampleDeletionConsuming: Sendable {
        /// Forwards one page's deleted sample UUIDs and remembers the server
        /// ids of its deleted HealthLog copies. `nil` when every one is
        /// accounted for (sent, kept in the outbox, refused for good, of a type
        /// whose deletions are not forwarded, or remembered); otherwise why the
        /// cursor must hold.
        func consumeDeletions(
            _ externalIDs: [String],
            copiesOf serverIDs: [String],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason?
    }

    extension AnchoredHealthSampleCollector {
        /// One live page: its samples, then its deletions. A deletion that is
        /// neither sent nor kept turns the page into a held one, so the commit
        /// rule, the single decision point, keeps the cursor before it.
        func consumeLive(
            _ page: AnchoredHealthSamplePage,
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            let outcome = await consumer.consume(page.samples, ofType: typeIdentifier, requiring: lease)
            // A page that holds anyway is read again, its deletions with it.
            guard !page.deletedSampleIDs.isEmpty || !page.deletedCopyServerIDs.isEmpty,
                  let deletions = consumer as? any HealthSampleDeletionConsuming,
                  HealthSyncCursorPolicy.installed.decide(outcome) == .commit else { return outcome }
            guard let held = await deletions.consumeDeletions(
                page.deletedSampleIDs,
                copiesOf: page.deletedCopyServerIDs,
                ofType: typeIdentifier,
                requiring: lease
            ) else { return outcome }
            return outcome.holding(held)
        }
    }

    extension HealthSyncPageOutcome {
        /// The same page, held by the commit rule for `reason`.
        func holding(_ reason: HealthSyncHoldReason) -> HealthSyncPageOutcome {
            var held = HealthSyncPageOutcome(
                postedCount: postedCount,
                entries: entries,
                transportThrew: transportThrew,
                durableRetryPersisted: durableRetryPersisted,
                durableRetryFailed: durableRetryFailed || [.retryPersistenceFailed, .nonterminalEntry, .incompleteIndexCoverage]
                    .contains(reason),
                leaseIsCurrent: leaseIsCurrent && reason != .leaseLost,
                wasCancelled: wasCancelled || reason == .cancelled
            )
            held.serverUnreachable = serverUnreachable || reason == .serverUnreachable
            held.foldedWindowDuplicates = foldedWindowDuplicates
            return held
        }
    }
#endif
