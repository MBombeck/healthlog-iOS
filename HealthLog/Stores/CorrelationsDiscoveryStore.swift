import Foundation
import Observation

/// `@Observable` wrapper over `CorrelationsDiscoveryRepository` +
/// `PatternsRepository`. Hydrates the discovered-correlations block on the
/// Insights overview — the FDR-controlled behaviour × outcome associations the
/// server surfaces, each carrying `n / r / p / q` and a conservative,
/// descriptive interpretation — and owns the relevance statement the person can
/// make about each one.
///
/// **DESCRIPTIVE, NEVER CAUSAL.** The store carries the server's own
/// statistical associations through verbatim; it adds no causal framing. The
/// view renders "X hängt mit Y zusammen", never "X verbessert Y".
///
/// **HONEST-ONLY + self-suppressing.** The store surfaces ONLY the pairs the
/// server returns. When the surface is gated off (`404`/`422` → repo `nil`) OR
/// there are no statistically-defensible pairs, ``presentable`` is empty and
/// the block hides — not an error, not an empty box.
///
/// ## CU-33 — "not relevant for me" is a statement, not a delete
///
/// `GET /api/insights/correlations` returns dismissed pairs INLINE with
/// `dismissed: true`; suppressing them is the client's job. This store does
/// that suppression (``presentable``) while keeping them reachable
/// (``dismissedPairs``) so the person can take the statement back — the server
/// accepts `{ dismissed: false }` on the same route.
///
/// **Dismissal is server-authoritative and re-read every fetch.** The very GET
/// that lists the pairs also runs the recomputation that can CLEAR a dismissal
/// on its own: when the effect flips sign, moves by ≥ 0.10, or the sample grows
/// by ≥ max(10, 25 %) *measured against the evidence at the moment of
/// dismissal*, the server drops the dismissal and the pair returns with
/// `dismissed: false`. The store never treats a local dismissal as durable
/// truth; it only remembers, in memory, which pairs the person dismissed *this
/// session* so a returning pair can be introduced calmly (``resurfacedIDs``)
/// instead of looking like the app lost the setting.
@MainActor
@Observable
public final class CorrelationsDiscoveryStore {
    /// The full server response, or `nil` when the surface is gated off / not
    /// yet loaded. The honest footer ("X Paare geprüft") reads `pairsTested`.
    public private(set) var response: CorrelationDiscoveryResponse?
    public private(set) var isLoading: Bool = false
    /// Set when a relevance statement could NOT be saved. The optimistic change
    /// has already been rolled back at that point — this is what tells the
    /// person so, rather than leaving a lie on screen.
    public private(set) var actionError: String?
    /// Pairs whose relevance statement is currently in flight (by
    /// ``DiscoveredCorrelation/id``), so the view can disable the control
    /// instead of queueing conflicting writes.
    public private(set) var pendingIDs: Set<String> = []

    /// Pairs the server brought back on its own (by
    /// ``DiscoveredCorrelation/id``) after they had been dismissed in this
    /// session, because the evidence changed materially. The view introduces
    /// them calmly — it is a data update, not a failure and not a lost setting.
    public private(set) var resurfacedIDs: Set<String> = []

    /// Pairs the person dismissed during THIS app session. In memory only and
    /// never persisted — it exists solely to recognise a server-initiated
    /// return, never to override the server's state.
    private var dismissedThisSession: Set<String> = []

    private let repo: CorrelationsDiscoveryRepository
    private let patterns: PatternsRepository
    /// Lazily-read ledger, used only to recover a `patternId` for a pair the
    /// correlations payload did not attach a decision to.
    private var ledger: [CorrelationPattern]?

    public init(repo: CorrelationsDiscoveryRepository, patterns: PatternsRepository) {
        self.repo = repo
        self.patterns = patterns
    }

    // MARK: - Reading

    /// The discovered pairs the block actually renders, strongest association
    /// first (`|r|` descending) so the most notable relationship leads.
    ///
    /// Pairs the person marked as not relevant are filtered OUT here — the
    /// server does not filter them on this route, so the client must.
    public var presentable: [DiscoveredCorrelation] {
        sortedByStrength(all.filter { !$0.isDismissed })
    }

    /// The pairs the person marked as not relevant, kept reachable so the
    /// statement stays reversible. Same strongest-first ordering.
    public var dismissedPairs: [DiscoveredCorrelation] {
        sortedByStrength(all.filter(\.isDismissed))
    }

    /// Whether the block has anything to show — including the case where every
    /// pair has been marked not relevant, because the person must still be able
    /// to reach them and take that back.
    public var hasContent: Bool {
        !presentable.isEmpty || !dismissedPairs.isEmpty
    }

    private var all: [DiscoveredCorrelation] {
        response?.discovered ?? []
    }

    private func sortedByStrength(_ pairs: [DiscoveredCorrelation]) -> [DiscoveredCorrelation] {
        pairs.sorted { abs($0.r) > abs($1.r) }
    }

    // MARK: - Loading

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        await apply((try? repo.fetch()) ?? response)
    }

    public func refresh() async {
        // A refresh must reflect a surface that turned OFF (gated) too, so it
        // clears to the fresh result rather than keeping a stale snapshot.
        isLoading = true
        defer { isLoading = false }
        await apply(try? repo.fetch())
    }

    public func clearOnLogout() {
        response = nil
        actionError = nil
        pendingIDs = []
        dismissedThisSession = []
        resurfacedIDs = []
        ledger = nil
    }

    /// Installs a freshly-read response and reconciles the session's dismissal
    /// memory against it. The server's `dismissed` always wins.
    private func apply(_ fresh: CorrelationDiscoveryResponse?) {
        defer { response = fresh }
        guard let fresh else { return }
        for pair in fresh.discovered where dismissedThisSession.contains(pair.id) && !pair.isDismissed {
            // The server lifted the dismissal during its recomputation. Note it
            // so the card can say why it is back, and stop tracking it.
            dismissedThisSession.remove(pair.id)
            resurfacedIDs.insert(pair.id)
        }
    }

    // MARK: - Relevance statement (optimistic, with rollback)

    /// Records "not relevant for me" (`dismissed: true`) or takes that back
    /// (`false`) for one pair.
    ///
    /// The change is applied to the in-memory response FIRST so the surface
    /// answers immediately, then confirmed against the server. On any failure
    /// the previous state is restored verbatim and ``actionError`` explains
    /// that nothing changed — an optimistic update that cannot be confirmed is
    /// rolled back, never left standing as a lie.
    public func setDismissed(_ dismissed: Bool, for pair: DiscoveredCorrelation) async {
        actionError = nil
        guard response != nil, !pendingIDs.contains(pair.id) else { return }
        guard let patternId = await resolvePatternId(for: pair) else {
            actionError = Self.unavailableMessage
            return
        }

        pendingIDs.insert(pair.id)
        defer { pendingIDs.remove(pair.id) }
        // Snapshot AFTER the ledger lookup so a refresh that landed during it is
        // the state we would roll back to, not a stale pre-lookup one.
        guard let snapshot = response else { return }
        applyDismissed(dismissed, to: pair.id)

        do {
            let settled = try await patterns.setDismissed(dismissed, patternId: patternId)
            // The server's settled state wins over what we sent.
            applyDismissed(settled.dismissed, to: pair.id)
            if settled.dismissed {
                dismissedThisSession.insert(pair.id)
                resurfacedIDs.remove(pair.id)
            } else {
                dismissedThisSession.remove(pair.id)
            }
            // The cached correlations row still carries the old flag; drop it so
            // the next launch paints the statement, not the state before it.
            await repo.invalidateCache()
        } catch {
            response = snapshot
            actionError = Self.message(for: error)
        }
    }

    private func applyDismissed(_ dismissed: Bool, to id: String) {
        guard var current = response else { return }
        for index in current.discovered.indices where current.discovered[index].id == id {
            current.discovered[index].dismissed = dismissed
        }
        response = current
    }

    /// The `patternId` for a pair: straight from the correlations payload when
    /// the server attached a decision, otherwise recovered from the pattern
    /// ledger by the `(factor, outcome, lag)` identity triple — the same triple
    /// the server's canonical key is derived from.
    private func resolvePatternId(for pair: DiscoveredCorrelation) async -> String? {
        if let patternId = pair.patternId { return patternId }
        if ledger == nil {
            ledger = await (try? patterns.fetch()) ?? []
        }
        return ledger?
            .first { $0.matches(factorKey: pair.behaviour, outcomeKey: pair.outcome, lagDays: pair.lagDays) }?
            .id
    }

    // MARK: - Failure copy

    private static var unavailableMessage: String {
        String(
            localized: "This relationship can’t be updated right now.",
            comment: "Correlation dismissal — no pattern handle available for this pair"
        )
    }

    private static func message(for error: Error) -> String {
        if case let HLError.server(status, _, _) = error, status == 404 {
            return String(
                localized: "This relationship is no longer current, so it can’t be updated.",
                comment: "Correlation dismissal — the pattern was withdrawn server-side (404)"
            )
        }
        return String(
            localized: "That couldn’t be saved just now — nothing was changed.",
            comment: "Correlation dismissal — the optimistic change was rolled back"
        )
    }
}
