import Foundation
import Observation

/// `@Observable` wrapper over ``DailyDigestRepository`` backing the dashboard
/// `TodayHeroCard`. Renders the server-authoritative ``DailyDigest`` verbatim —
/// it recomputes nothing and warms no AI on load.
///
/// **Presentation contract (mirrors the web `TodayHero` state machine).**
/// ``presentation`` collapses the raw (digest / loading / error) triple into the
/// four states the hero paints:
///   - `.loading` — first cold load, no digest yet → the no-layout-shift
///     skeleton;
///   - `.data(digest)` — a present, non-degrade digest → the hero;
///   - `.hidden` — the calm degrade (score + rail + briefing all empty) OR an
///     absent digest (404 / gated off) → render NOTHING (the tile strip below
///     carries the first-run empty state);
///   - `.error(err)` — first load failed with no cached digest → a retry card.
/// A background-refresh failure never blanks a good hero: the last-good digest
/// stays until a fresh success replaces it.
@MainActor
@Observable
public final class DailyDigestStore {
    public private(set) var digest: DailyDigest?
    public private(set) var isLoading: Bool = false
    public private(set) var hasLoadedOnce: Bool = false
    public private(set) var error: HLError?
    /// True while a coach check-in keep / let-go mutation is in flight, so the
    /// card's action buttons can disable to block a double-tap.
    public private(set) var coachActionInFlight: Bool = false

    private let repo: DailyDigestRepository

    public init(repo: DailyDigestRepository) {
        self.repo = repo
    }

    /// The four hero states (see type doc). Not `Equatable` — the view switches
    /// on it directly and `HLError` carries no cheap equality.
    public enum Presentation {
        case loading
        case data(DailyDigest)
        case hidden
        case error(HLError)
    }

    public var presentation: Presentation {
        if let digest {
            return digest.isEmptyDegrade ? .hidden : .data(digest)
        }
        if !hasLoadedOnce, isLoading { return .loading }
        // No digest to show: any load error surfaces the retry card. (A background-
        // refresh failure that had a cached digest never reaches here — `load()`
        // preserves the last-good `digest`, so the `if let digest` branch wins.)
        if let error { return .error(error) }
        return .hidden
    }

    /// Fetch the digest. Single-flighted (a concurrent call while one is in
    /// flight is a no-op) so the cold-launch `.task` + a scenePhase refresh
    /// never double-fetch. On a `nil` result (gated off / absent) the store
    /// clears to the hidden state; on error the last-good digest is preserved.
    public func load() async {
        if isLoading { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            let result = try await repo.fetch()
            digest = result
            error = nil
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func refresh() async {
        await load()
    }

    /// Dismiss an observational rail item. Optimistically removes the card, then
    /// calls the endpoint; a failure reloads so the true server state wins.
    public func dismiss(itemKey: String) async {
        guard let current = digest else { return }
        let pruned = current.worthALook.filter { $0.itemKey != itemKey }
        digest = current.withWorthALook(pruned)
        do {
            try await repo.dismiss(itemKey: itemKey)
        } catch {
            await load()
        }
    }

    /// Coach check-in **keep** — re-arm the plan, then reload so the card
    /// leaves the rail (the server drops it once re-armed).
    public func coachCheckinKeep(planId: String) async {
        await runCoachAction { try await self.repo.coachCheckinKeep(planId: planId) }
    }

    /// Coach check-in **let-go** — retire the plan, then reload.
    public func coachCheckinLetGo(planId: String) async {
        await runCoachAction { try await self.repo.coachCheckinLetGo(planId: planId) }
    }

    public func clearOnLogout() {
        digest = nil
        error = nil
        isLoading = false
        hasLoadedOnce = false
        coachActionInFlight = false
    }

    // MARK: - Private

    private func runCoachAction(_ mutation: () async throws -> Void) async {
        if coachActionInFlight { return }
        coachActionInFlight = true
        defer { coachActionInFlight = false }
        do {
            try await mutation()
        } catch {
            // Swallow the mutation error — the reload below re-reads the true
            // plan state, so a transient failure just leaves the card in place.
        }
        await load()
    }
}

private extension DailyDigest {
    /// A copy with a pruned rail — used for the optimistic dismiss so the card
    /// disappears immediately while the endpoint call is in flight.
    func withWorthALook(_ items: [DailyPriorityItem]) -> DailyDigest {
        DailyDigest(
            generatedAt: generatedAt,
            phase: phase,
            sleepPending: sleepPending,
            score: score,
            topSignal: topSignal,
            briefingLead: briefingLead,
            line: line,
            worthALook: items
        )
    }
}
