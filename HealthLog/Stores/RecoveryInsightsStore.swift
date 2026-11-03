import Foundation
import Observation

/// `@Observable` wrapper over `RecoveryInsightsRepository`. Hydrates the
/// Insights **Recovery** page and carries the HRV measure decision the HRV
/// page reads.
///
/// **Server-authoritative.** The family is the server's summaries, the trend
/// lines are the server's readings; nothing here recomputes a value.
///
/// **1.4 B3 — trend lines.** After the family, the store loads the readings
/// for each trend card through `MeasurementsRepository.recent(kind:limit:)`,
/// the very read the metric screen behind the card makes (same query, same
/// SWR row), so opening the card's detail is instant and both show the same
/// readings.
@MainActor
@Observable
public final class RecoveryInsightsStore {
    /// The latest built family, or `nil` when the slice is gated, absent or has
    /// not loaded yet.
    public private(set) var family: RecoveryInsightsDTO?
    public private(set) var isLoading: Bool = false
    /// `true` once a load has completed at least once this session — lets the
    /// page tell "still loading" from "settled".
    public private(set) var hasSettledOnce: Bool = false
    /// `true` when the last load failed and there is no family to show. The
    /// page then offers a retry instead of claiming there is no data.
    public private(set) var loadFailed: Bool = false
    /// Each trend card's readings, the same page the metric screen reads; the
    /// card draws the last 30 days of it (``RecoveryPageLayout/trendPoints``).
    /// A kind is absent until its read returned.
    public private(set) var trendReadings: [MetricKind: [Measurement]] = [:]

    /// The page read for one trend kind. `nil` in tests that only exercise the
    /// family.
    public typealias ReadingsLoader = @Sendable (MetricKind) async throws -> [Measurement]

    private let repo: RecoveryInsightsRepository
    private let readings: ReadingsLoader?

    public init(repo: RecoveryInsightsRepository, readings: ReadingsLoader? = nil) {
        self.repo = repo
        self.readings = readings
    }

    /// `true` when at least one family type has a current reading.
    public var hasContent: Bool {
        family?.hasContent ?? false
    }

    /// What the page shows, derived from the family.
    public var layout: RecoveryPageLayout {
        RecoveryPageLayout(family: family)
    }

    /// The measure the page for `kind` shows. The HRV page shows RMSSD when
    /// the server reports no SDNN reading in the last 30 days but an RMSSD one;
    /// every other kind shows itself.
    public func displayKind(for kind: MetricKind) -> MetricKind {
        kind == .hrv && family?.hrvShowsRMSSD == true ? .hrvRMSSD : kind
    }

    public func load() async {
        await load(forceRevalidate: false)
    }

    /// Pull-to-refresh: revalidates the family against the server.
    public func refresh() async {
        await load(forceRevalidate: true)
    }

    public func clearOnLogout() {
        family = nil
        trendReadings = [:]
        loadFailed = false
        hasSettledOnce = false
    }

    private func load(forceRevalidate: Bool) async {
        isLoading = true
        defer {
            isLoading = false
            hasSettledOnce = true
        }
        do {
            family = try await repo.fetch(forceRevalidate: forceRevalidate)
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            // Keep a family already on screen; only an empty page turns into
            // the retry face.
            loadFailed = family == nil
            if family == nil { return }
        }
        await loadTrendReadings()
    }

    private func loadTrendReadings() async {
        guard let readings else { return }
        for kind in layout.trendKinds {
            // A failed line keeps the card (its numbers are the family's) and
            // only loses the line; the next refresh retries.
            if let rows = try? await readings(kind) {
                trendReadings[kind] = rows
            }
        }
    }
}
