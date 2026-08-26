import Foundation

/// **W-B187 QOL-2 — the app-side bridge between the live stores and the
/// CoreSpotlight index writer.**
///
/// `@MainActor` so the stores can call it directly from their settle hooks
/// (they already run on the main actor). It does the *cheap* main-actor work
/// — map the model arrays to `Sendable` ``SpotlightIndexer/Entry`` snapshots,
/// resolve neutral localized titles + Insights slugs — then hands the
/// snapshot to the off-main-actor ``SpotlightIndexer`` and returns. No index
/// I/O blocks the main actor.
///
/// **Privacy:** only medication NAMES and neutral measured-kind titles cross
/// into the index (see `SpotlightItemBuilder` for the PHI guard). No reading,
/// value, or date is ever indexed.
@MainActor
final class SpotlightCoordinator {
    private let indexer: SpotlightIndexer

    /// The measured-kind title resolver — injectable so the title source
    /// (`MetricKind.displayName`) can be stubbed in tests without the full
    /// xcstrings bundle. Production uses the live localized display name.
    private let measurementTitle: @MainActor (MetricKind) -> String

    /// The Insights deep-link slug resolver — injectable for the same reason.
    /// Production uses `InsightsTabSlug.slug(forKind:)`; a kind with no
    /// Insights page returns `nil` and is not indexed.
    private let measurementSlug: @MainActor (MetricKind) -> String?

    init(
        indexer: SpotlightIndexer = SpotlightIndexer(),
        measurementTitle: @escaping @MainActor (MetricKind) -> String = { $0.displayName },
        measurementSlug: @escaping @MainActor (MetricKind) -> String? = { InsightsTabSlug.slug(forKind: $0) }
    ) {
        self.indexer = indexer
        self.measurementTitle = measurementTitle
        self.measurementSlug = measurementSlug
    }

    /// Re-index the medications sub-domain from the current list. Archived
    /// medications are skipped (they're not actionable from search). Fire-
    /// and-forget — the caller doesn't await.
    func reindexMedications(_ medications: [Medication]) {
        let entries: [SpotlightIndexer.Entry] = medications.compactMap { medication in
            guard medication.archivedAt == nil else { return nil }
            let name = medication.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { return nil }
            return SpotlightIndexer.Entry(kind: .medication(id: medication.id), title: name)
        }
        let indexer = indexer
        Task.detached(priority: .utility) {
            await indexer.replace(entries, in: .medications)
        }
    }

    /// Re-index the measurements sub-domain from the set of kinds the user
    /// actually has data for. Indexes a NEUTRAL category title + Insights
    /// deep-link per kind — never a value. Fire-and-forget.
    func reindexMeasurements(kinds: [MetricKind]) {
        let entries: [SpotlightIndexer.Entry] = kinds.compactMap { kind in
            guard let slug = measurementSlug(kind) else { return nil }
            return SpotlightIndexer.Entry(kind: .measurement(slug: slug), title: measurementTitle(kind))
        }
        let indexer = indexer
        Task.detached(priority: .utility) {
            await indexer.replace(entries, in: .measurements)
        }
    }

    /// Tear down the whole HealthLog Spotlight index — called on logout so
    /// no medication name survives into a signed-out device's system search.
    func clearAll() {
        let indexer = indexer
        Task.detached(priority: .utility) {
            await indexer.deleteAll()
        }
    }
}
