import Foundation
#if canImport(CoreSpotlight)
    import CoreSpotlight
#endif

/// **W-B187 QOL-2 — the CoreSpotlight index writer.**
///
/// An `actor` so the (potentially I/O-bound) index writes run **off the
/// main actor** — the `@MainActor` stores hand it a plain `[SpotlightEntry]`
/// snapshot and return immediately; the actual `CSSearchableIndex` calls
/// happen on this actor's executor. Incremental by design: re-indexing one
/// content class (`replace(_:in:)`) only ever touches that sub-domain, so a
/// medications change doesn't churn the measurements items and vice versa.
///
/// The whole HealthLog index is torn down on logout (`deleteAll()`) so a
/// signed-out device can't surface a previous user's medication names in
/// system search.
actor SpotlightIndexer {
    /// A minimal, `Sendable` description of one item to index — the stores
    /// build these on the main actor (cheap, value types) and hand the array
    /// across the actor boundary, keeping the model types out of the indexer.
    struct Entry: Equatable {
        enum Kind: Equatable {
            case medication(id: String)
            case measurement(slug: String)
        }

        let kind: Kind
        let title: String
    }

    #if canImport(CoreSpotlight)
        /// Injectable index seam. Production uses `CSSearchableIndex.default()`;
        /// tests pass a stub conforming to ``SpotlightIndexWriting`` so the
        /// indexer's batching / delete logic is verifiable without the live
        /// system index. `nil` when device indexing is disabled — every method
        /// then no-ops cleanly.
        private let index: SpotlightIndexWriting?

        init(index: SpotlightIndexWriting? = SpotlightIndexer.defaultIndex()) {
            self.index = index
        }

        static func defaultIndex() -> SpotlightIndexWriting? {
            guard CSSearchableIndex.isIndexingAvailable() else { return nil }
            return CSSearchableIndex.default()
        }
    #else
        init() {}
    #endif

    /// Replace all items in one sub-domain with the supplied entries. Builds
    /// the `CSSearchableItem`s via the pure ``SpotlightItemBuilder`` (which
    /// enforces the PHI guard + deep-link allowlist), then atomically swaps
    /// the domain's contents. Entries that fail the builder (non-routable id,
    /// PHI-shaped title) are silently dropped — never indexed.
    func replace(_ entries: [Entry], in domain: SpotlightItemBuilder.Domain) async {
        #if canImport(CoreSpotlight)
            guard let index else { return }
            let items: [CSSearchableItem] = entries.compactMap { entry in
                switch entry.kind {
                case let .medication(id):
                    SpotlightItemBuilder.medicationItem(id: id, name: entry.title)
                case let .measurement(slug):
                    SpotlightItemBuilder.measurementItem(slug: slug, title: entry.title)
                }
            }
            do {
                // Clear the sub-domain first so a removed medication / kind
                // doesn't linger, then index the fresh set. Both calls scope
                // to the one sub-domain — the other class is untouched.
                try await index.hlDeleteItems(inDomains: [domain.rawValue])
                if items.isEmpty == false {
                    try await index.hlIndexItems(items)
                }
            } catch {
                // Indexing is best-effort — a failure must never surface to
                // the user or break a store load. Log + move on.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.ui.debug("Spotlight re-index failed for \(domain.rawValue, privacy: .public)")
            }
        #else
            _ = entries
            _ = domain
        #endif
    }

    /// Tear down the entire HealthLog Spotlight index — called on logout so
    /// no medication name survives into a signed-out device's system search.
    func deleteAll() async {
        #if canImport(CoreSpotlight)
            guard let index else { return }
            do {
                try await index.hlDeleteItems(
                    inDomains: [
                        SpotlightItemBuilder.Domain.medications.rawValue,
                        SpotlightItemBuilder.Domain.measurements.rawValue
                    ]
                )
            } catch {
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.ui.debug("Spotlight delete-all failed")
            }
        #endif
    }
}

#if canImport(CoreSpotlight)
    /// Index seam protocol so ``SpotlightIndexer`` can be unit-tested against a
    /// stub. `CSSearchableIndex` conforms via the conditional extension below.
    /// The `hl`-prefixed method names avoid colliding (and overload-
    /// ambiguating) with `CSSearchableIndex`'s own `indexSearchableItems` /
    /// `deleteSearchableItems(withDomainIdentifiers:)` family. CoreSpotlight is
    /// always linked in the iOS app target, so the whole seam is guarded on it
    /// — this lets the items cross the actor boundary as the strongly-typed
    /// `[CSSearchableItem]` (a Sendable-safe transfer of fresh, builder-made
    /// value objects) rather than a non-Sendable `[Any]`.
    protocol SpotlightIndexWriting: Sendable {
        func hlIndexItems(_ items: [CSSearchableItem]) async throws
        func hlDeleteItems(inDomains identifiers: [String]) async throws
    }

    /// Adapter onto the real `CSSearchableIndex` API.
    extension CSSearchableIndex: SpotlightIndexWriting {
        func hlIndexItems(_ items: [CSSearchableItem]) async throws {
            try await indexSearchableItems(items)
        }

        func hlDeleteItems(inDomains identifiers: [String]) async throws {
            try await deleteSearchableItems(withDomainIdentifiers: identifiers)
        }
    }
#endif
