import Foundation
import Observation

/// Where the hypnogram reads a night from: the cached stale half and the
/// server's fresh half of one day-key (`nil` = the latest night).
struct SleepNightSource: Sendable {
    let cached: @Sendable (String?) async -> SleepNightDTO?
    let fresh: @Sendable (String?) async throws -> SleepNightDTO

    init(
        cached: @escaping @Sendable (String?) async -> SleepNightDTO?,
        fresh: @escaping @Sendable (String?) async throws -> SleepNightDTO
    ) {
        self.cached = cached
        self.fresh = fresh
    }

    init(repository: SleepNightRepository) {
        cached = { await repository.cachedNight(forDayKey: $0) }
        fresh = { try await repository.night(forDayKey: $0) }
    }
}

/// The hypnogram's load state, stale-while-revalidate per day-key (W-B180).
///
/// **One load owns the page at a time (D5 #3).** Tapping the arrow twice
/// quickly starts a second load while the first one still waits on the
/// server. The first load used to write its night, `isLoading = false` and
/// perhaps `loadError` after its `await` anyway, so night A could appear under
/// date B (for good, if B's own load then failed), and the spinner vanished
/// into a flash of "no data". Every load now takes a generation and publishes
/// only while it is still the newest and not cancelled.
@MainActor
@Observable
final class SleepHypnogramLoader {
    private(set) var night: SleepNightDTO?
    private(set) var isLoading: Bool
    private(set) var loadError = false
    /// The LATEST night's day-key, resolved from the first no-date load: the
    /// right edge of the navigation (no browsing into the future).
    private(set) var latestDayKey: String?

    @ObservationIgnored private var generation = 0

    init(initialNight: SleepNightDTO?) {
        night = initialNight
        isLoading = initialNight == nil
        // Seed the navigation anchor so test/preview hosts (no repository →
        // no latest-load) still show the night header for the seeded night.
        latestDayKey = initialNight.flatMap(SleepHypnogramScreen.anchorDayKey(for:))
    }

    func load(dayKey: String?, from source: SleepNightSource?) async {
        generation += 1
        let token = generation
        guard let source else {
            isLoading = false
            return
        }
        loadError = false
        // Stale half: paint a previously seen night instantly (no spinner)…
        let cached = await source.cached(dayKey)
        guard isCurrent(token) else { return }
        if let cached {
            night = cached
            isLoading = false
        } else {
            isLoading = true
            night = nil
        }
        // …revalidate half: always refresh against the server.
        do {
            let fresh = try await source.fresh(dayKey)
            guard isCurrent(token) else { return }
            night = fresh
            if dayKey == nil, let anchor = SleepHypnogramScreen.anchorDayKey(for: fresh) {
                latestDayKey = anchor
            }
        } catch {
            guard isCurrent(token) else { return }
            if night == nil { loadError = true }
        }
        isLoading = false
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled
    }
}
