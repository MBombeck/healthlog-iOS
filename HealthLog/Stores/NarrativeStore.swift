import Foundation
import Observation

/// `@Observable` wrapper over ``NarrativeRepository``. Drives the
/// "Zeitraum im Rückblick" retrospective card on the Insights overview
/// (I-3 ITEM 5) — display-only, server-sourced, week/month toggle.
///
/// **Per-period cache.** The card has a week/month toggle, so the store keeps a
/// resolved ``NarrativeDTO`` per period and loads each lazily on first request
/// (and on a forced refresh). Switching the toggle paints the already-resolved
/// period instantly; a never-loaded period triggers its own fetch.
///
/// **Self-suppression contract.** ``narrative(for:)`` returns `nil` whenever the
/// server returned no narrative, the route 404/422'd (repo returned `nil`), or a
/// read error left the store cold — the card renders a calm empty state, never a
/// spinner-forever (see the `isLoading` gate in the view).
@MainActor
@Observable
public final class NarrativeStore {
    /// Resolved DTO per period (`nil` value = loaded-but-empty / no-route).
    public private(set) var byPeriod: [NarrativeDTO.Period: NarrativeDTO?] = [:]
    /// Periods with an in-flight load (drives the per-period spinner gate).
    public private(set) var loading: Set<NarrativeDTO.Period> = []
    /// I-3/F1 — periods whose last load FAILED with a transport error (5xx /
    /// offline), so the card can show a distinct calm "couldn't load" hint
    /// instead of conflating a server outage with a genuinely-empty period. A
    /// `404`/`422` does NOT land here (the repo returns `nil` → settled-empty);
    /// only a thrown error does. Cleared the moment a period's load is retried.
    public private(set) var errored: Set<NarrativeDTO.Period> = []
    /// v0.14.6 H2 — periods whose server returned `revalidating: true,
    /// narrative: null` (a background AI warm is in flight) and for which a
    /// bounded in-session re-poll is scheduled. Lets the card show an honest
    /// "preparing your retrospective…" hint during the warm window instead of
    /// the "not enough data yet" empty copy — two very different messages: the
    /// former promises content is coming (and it swaps in-session once warmed),
    /// the latter reads as "never". Cleared the moment the period settles or
    /// the re-poll cap is hit.
    public private(set) var warming: Set<NarrativeDTO.Period> = []
    public private(set) var error: HLError?

    private let repo: NarrativeRepository

    public init(repo: NarrativeRepository) {
        self.repo = repo
    }

    /// The resolved narrative text for a period, or `nil` when none exists yet.
    public func narrative(for period: NarrativeDTO.Period) -> NarrativeDTO.Narrative? {
        // `byPeriod[period]` is a double-optional (`NarrativeDTO??`): the outer
        // optional is "key present?", the inner is "loaded but empty". Flatten
        // both — only a present, non-nil DTO carries a narrative.
        guard case let .some(.some(dto)) = byPeriod[period] else { return nil }
        return dto.narrative
    }

    /// `true` once a period has settled (loaded-empty counts as settled), so the
    /// view can distinguish "still loading" from "loaded, but empty".
    public func hasSettled(_ period: NarrativeDTO.Period) -> Bool {
        byPeriod.index(forKey: period) != nil
    }

    public func isLoading(_ period: NarrativeDTO.Period) -> Bool {
        loading.contains(period)
    }

    /// I-3/F1 — `true` when this period's last load threw a transport error and
    /// no narrative has since resolved, so the card shows the "couldn't load"
    /// hint rather than the empty state.
    public func hasErrored(_ period: NarrativeDTO.Period) -> Bool {
        errored.contains(period)
    }

    /// v0.14.6 H2 — `true` while a background AI warm is in flight for this
    /// period and a re-poll is scheduled, so the card shows "preparing…" rather
    /// than the settled-empty copy.
    public func isWarming(_ period: NarrativeDTO.Period) -> Bool {
        warming.contains(period)
    }

    /// v0.14.3 B5 — number of in-session re-polls already issued per period
    /// when the server returned `revalidating: true, narrative: null` (a warm
    /// is in flight). Capped so a never-warming provider can't loop forever.
    private var revalidatePolls: [NarrativeDTO.Period: Int] = [:]
    /// L-1 — the pending warm re-polls, held so logout can cancel them.
    ///
    /// N5.2 (v0.14.8 tech audit) — keyed **per period**: the store previously
    /// tracked ONE task across both periods, so scheduling a warm re-poll for
    /// month silently cancelled a pending week re-poll (and vice versa) — the
    /// cancelled period froze on its loading/empty arm until a manual refresh.
    /// One pending task per period; replacing a period's own task still cancels
    /// the prior one (no double-poll per period).
    private var revalidateTasks: [NarrativeDTO.Period: Task<Void, Never>] = [:]
    /// Re-poll cap + delay for the warm-in-flight case (B5).
    private static let maxRevalidatePolls = 3
    private static let revalidatePollDelay: Duration = .seconds(4)

    /// Loads a single period. Skips the network when already settled unless
    /// `force` is set (pull-to-refresh / toggle-refresh).
    ///
    /// **v0.14.3 B5 — warm-in-flight re-poll.** When the server returns
    /// `narrative: nil` together with `revalidating: true`, a fresh narrative is
    /// being warmed out-of-band. Settling the key would freeze the empty state
    /// until the next Berlin-day rollover. Instead we keep the period UNSETTLED
    /// and schedule a short-delay re-poll (capped) so a freshly-warmed narrative
    /// appears in the SAME session.
    public func load(period: NarrativeDTO.Period, locale: String, force: Bool = false) async {
        if !force, hasSettled(period) { return }
        loading.insert(period)
        error = nil
        // F1 — a retry clears the prior error so the card drops the "couldn't
        // load" hint while the new attempt is in flight.
        errored.remove(period)
        defer { loading.remove(period) }
        do {
            let dto = try await repo.fetch(period: period, locale: locale)
            // B5 — warm in flight + still empty → don't settle; re-poll soon.
            if let dto, dto.narrative == nil, dto.revalidating == true,
               (revalidatePolls[period] ?? 0) < Self.maxRevalidatePolls
            {
                revalidatePolls[period, default: 0] += 1
                // H2 — mark the period as warming so the card shows an honest
                // "preparing…" hint (content is coming) instead of the
                // settled-empty "not enough data" copy during the re-poll window.
                warming.insert(period)
                // Do NOT write `byPeriod[period]` — leave it unsettled so the
                // card keeps showing its loading/empty arm and re-polls.
                // L-1 — hold the handle so `clearOnLogout` can cancel a pending
                // re-poll (otherwise a ~4 s-later fetch fires on a logged-out
                // session; it 401-self-heals, but the cancel avoids the spurious
                // request entirely). N5.2 — keyed per period so week/month warm
                // windows never cancel each other.
                revalidateTasks[period]?.cancel()
                revalidateTasks[period] = Task { [weak self] in
                    try? await Task.sleep(for: Self.revalidatePollDelay)
                    if Task.isCancelled { return }
                    await self?.load(period: period, locale: locale, force: true)
                }
                return
            }
            revalidatePolls[period] = nil
            // N5.2 — the period settled; drop its pending re-poll handle (the
            // running task, if this IS the re-poll, is past its sleep already).
            revalidateTasks[period] = nil
            // H2 — warm window over (settled with content, or cap hit): drop
            // the warming flag so the card resolves to prose or the honest
            // empty state.
            warming.remove(period)
            byPeriod[period] = dto
        } catch let err as HLError {
            error = err
            errored.insert(period)
            warming.remove(period)
        } catch {
            self.error = .unknown(String(describing: error))
            errored.insert(period)
            warming.remove(period)
        }
    }

    /// Refreshes every period the store has already touched (pull-to-refresh).
    public func refresh(locale: String) async {
        let periods = byPeriod.isEmpty ? [NarrativeDTO.Period.week] : Array(byPeriod.keys)
        for period in periods {
            await load(period: period, locale: locale, force: true)
        }
    }

    public func clearOnLogout() {
        for task in revalidateTasks.values {
            task.cancel()
        }
        revalidateTasks = [:]
        byPeriod = [:]
        loading = []
        errored = []
        warming = []
        error = nil
        revalidatePolls = [:]
    }
}
