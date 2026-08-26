import Foundation

/// **W-REMINDERS (#23 v1.18.1) — Vorsorge measurement-reminder list store.**
///
/// `@MainActor @Observable` SWR store backing the manage-reminders screen.
/// Holds `[MeasurementReminderRow]` (server-sorted by `nextDueAt`), serves
/// cache-first via the `SWRCoordinator` (key `.measurementReminders`), and
/// revalidates in the background. When no coordinator is injected (tests /
/// standalone) it falls back to a direct `repo.list()`.
///
/// **Server-authoritative mutations (08-22).** No reminder action fabricates a
/// server-owned value. `satisfy`, `complete`, `skip` and `snooze` each leave the
/// pre-call row exactly as the server last described it, publish which action is
/// in flight through ``pendingAction`` so the surface can show progress instead
/// of a made-up figure, and reconcile **only** from the canonical row the
/// accepted envelope carries. On failure nothing moved, so there is nothing to
/// roll back; the reason is surfaced via `error`. `delete(id:)` still removes its
/// row optimistically and restores the pre-call snapshot on failure — it removes
/// a row rather than rebuilding one, so no field can be lost. Create / refresh /
/// edit re-list authoritatively.
///
/// **The store never constructs a `MeasurementReminderRow`.** Every row it holds
/// came off the wire. That is not a style preference: the previous
/// `optimisticallySatisfied` rebuilt a row field-by-field through the memberwise
/// init, so when v1.37.20 appended `snoozedUntil` / `lastSkippedAt` / `skipCount`
/// with defaults, the optimistic placeholder silently reset all three and a skip
/// badge blinked to zero for the duration of a request (08-19's handoff). A
/// rebuild deletes everything it forgets; not rebuilding cannot.
/// `MeasurementRemindersStoreTests` pins the absence as text.
///
/// `nextDueAt` / `lastSatisfiedAt` / `endsOn` / `snoozedUntil` / `lastSkippedAt`
/// are NEVER recomputed client-side — the server values are rendered verbatim,
/// and "snoozed" / "skipped cycle" are clock comparisons against them, which is
/// what the accepted contract tells clients to do.
@MainActor
@Observable
public final class MeasurementRemindersStore {
    public internal(set) var reminders: [MeasurementReminderRow] = []
    public internal(set) var isLoading = false
    public var error: HLError?

    /// Which server action is currently in flight for a reminder id. The surface
    /// renders progress from this instead of an optimistic value, which is the
    /// whole reason the optimistic placeholder could be deleted.
    public internal(set) var pendingAction: [String: MeasurementReminderAction] = [:]

    /// The reminder's completion ledger, keyed by reminder id. Absent = never
    /// asked; see ``MeasurementReminderLedger`` for the difference between "not
    /// asked", "honestly empty" and "not offered for this reminder".
    public internal(set) var ledgers: [String: MeasurementReminderLedger] = [:]

    /// Capabilities the server has refused for a reminder with a `404`.
    ///
    /// The accepted DTO publishes no field that distinguishes an appointment
    /// (encounter) reminder — the only rows that 404 on skip / snooze / history —
    /// so the capability is not knowable locally and can only be **learned from
    /// the refusal**. Once learned it is remembered for the session and the
    /// affordance is withdrawn rather than shown as a failure.
    public internal(set) var unsupportedActions: [String: Set<MeasurementReminderAction>] = [:]

    private let repo: MeasurementReminderRepository
    private let swr: SWRCoordinator?

    public init(repo: MeasurementReminderRepository, swr: SWRCoordinator? = nil) {
        self.repo = repo
        self.swr = swr
    }

    /// Drop in-memory reminder PHI + the cached list on logout so the next user
    /// never inherits the previous user's reminders (QA S-M2 — parity with the
    /// other PHI stores). The global SWR purge also clears the cache; this is the
    /// store-local belt-and-suspenders for when the store is held beyond a single
    /// screen's `@State`.
    ///
    /// The completion ledger is PHI too — every row is a dated fulfilment of a
    /// preventive-care reminder — so it drops here with everything else, along
    /// with the learned capability map and any in-flight marker.
    public func clearOnLogout() async {
        reminders = []
        pendingAction = [:]
        ledgers = [:]
        unsupportedActions = [:]
        error = nil
        await swr?.invalidate([.measurementReminders])
    }

    // MARK: - Load / refresh

    /// SWR load: paints cache-first, revalidates in background. `force == true`
    /// is the pull-to-refresh path (bypasses the staleness short-circuit).
    public func load(force: Bool = false) async {
        guard let swr else {
            await loadDirect()
            return
        }
        isLoading = true
        defer { isLoading = false }
        let repo = repo
        let stream = await swr.observe(
            .measurementReminders,
            decoding: [MeasurementReminderRow].self,
            forceRevalidate: force,
            fetch: { try await repo.list() }
        )
        for await state in stream {
            switch state {
            case .empty:
                continue
            case let .cached(value, _):
                reminders = value
            case let .fresh(value):
                reminders = value
                error = nil
            case let .failed(err, lastKnown):
                if let lastKnown { reminders = lastKnown }
                error = err
            }
        }
    }

    /// Direct (no-SWR) load — used in tests / standalone.
    private func loadDirect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            reminders = try await repo.list()
            error = nil
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    // MARK: - Mutations

    /// Create a Vorsorge reminder, then re-list authoritatively so the new row
    /// lands in the server's `nextDueAt`-sorted order. Returns `true` on success.
    @discardableResult
    public func create(_ body: MeasurementReminderCreate) async -> Bool {
        do {
            _ = try await repo.create(body)
            await reload()
            error = nil
            return true
        } catch let err as HLError {
            error = err
            return false
        } catch {
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// Edit an existing reminder via `PATCH /api/measurement-reminders/{id}`.
    /// The server recomputes `nextDueAt` after the cadence merge, so we reload
    /// rather than optimistically mutate (the new due date is server-authoritative
    /// and must never be predicted client-side). Returns `true` on success.
    @discardableResult
    public func update(id: String, patch: MeasurementReminderUpdate) async -> Bool {
        do {
            _ = try await repo.update(id: id, patch: patch)
            await reload()
            error = nil
            return true
        } catch let err as HLError {
            error = err
            return false
        } catch {
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// MANUAL "Erledigt" — the pre-call row stays exactly as the server last
    /// described it while the request is in flight (``pendingAction`` carries the
    /// progress), then the server's re-anchored row replaces it wholesale. On
    /// failure nothing moved, so there is nothing to restore.
    @discardableResult
    public func satisfy(id: String) async -> Bool {
        guard reminders.contains(where: { $0.id == id }) else { return false }
        return await run(.satisfy, id: id) { try await (true, self.repo.satisfy(id: id)) }.succeeded
    }

    /// EXPLICIT "Erledigt" completion (v1.18.6, #32) — the server-authoritative
    /// twin of `satisfy`. POSTs `…/{id}/complete` and reconciles with the
    /// server's canonical post-completion `reminder` (idempotent:
    /// `completed == false` is a no-op, and the row is still reconciled).
    /// Returns `true` when the server call succeeded, regardless of the
    /// idempotent flag.
    @discardableResult
    public func complete(id: String) async -> Bool {
        guard reminders.contains(where: { $0.id == id }) else { return false }
        return await run(.complete, id: id) {
            let result = try await self.repo.complete(id: id)
            return (result.completed, result.reminder)
        }.succeeded
    }

    /// Optimistically remove the row, then confirm the server soft-delete. On
    /// failure the row is restored at its original position.
    @discardableResult
    public func delete(id: String) async -> Bool {
        let snapshot = reminders
        reminders.removeAll { $0.id == id }
        do {
            try await repo.delete(id: id)
            await writeThrough()
            error = nil
            return true
        } catch let err as HLError {
            reminders = snapshot
            error = err
            return false
        } catch {
            reminders = snapshot
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    // MARK: - Helpers

    private func reload() async {
        if let swr {
            await swr.invalidate([.measurementReminders])
            await load(force: true)
        } else {
            await loadDirect()
        }
    }

    private func writeThrough() async {
        guard let swr else { return }
        await swr.writeThrough(.measurementReminders, value: reminders)
    }
}

// MARK: - ROUTE-07 (v1.37.20) — skip, snooze and the completion ledger

/// Which server call is in flight for a reminder, and which capability a `404`
/// has withdrawn. One vocabulary for both, because the surface asks the same
/// question of each: may I offer this, and is it happening right now?
public enum MeasurementReminderAction: String, Sendable, Hashable, CaseIterable {
    case satisfy
    case complete
    case skip
    case snooze
    case history
}

/// What a reminder action did, as the **server** reported it.
///
/// `noOp` and `unsupported` are deliberately not failures. `skipped == false` is
/// the accepted route's forward-only no-op and still carries the canonical row,
/// and a `404` is the deployment saying this reminder does not offer the
/// capability — an answer to respect, not an error to apologise for.
public enum MeasurementReminderActionOutcome: Sendable, Equatable {
    /// The server recorded the action; the canonical row replaced the local one.
    case applied
    /// The server accepted the call and reported a forward-only no-op; the
    /// canonical row still replaced the local one.
    case noOp
    /// The route refused this reminder with a `404`. Nothing changed, the
    /// capability is remembered as withdrawn, and no error is raised.
    case unsupported
    /// Everything else. Nothing changed; the reason is on the store's `error`.
    case failed(HLError)

    /// `true` when the call reached the server and returned a canonical row,
    /// regardless of the idempotent flag.
    public var succeeded: Bool {
        self == .applied || self == .noOp
    }
}

/// One reminder's completion ledger, exactly as the server has described it.
///
/// Three states a naive model collapses into one are kept apart on purpose:
/// **not asked** (`isLoaded == false`, not unsupported), **honestly empty**
/// (`isLoaded == true`, `meta.total == 0` — the ledger begins at the release
/// that introduced it and cannot be backfilled), and **not offered for this
/// reminder** (`isUnsupported`). Only the first two are about this reminder's
/// history; the third is about the route.
public struct MeasurementReminderLedger: Sendable, Equatable {
    /// Every event the server has returned, in the order the pages arrived —
    /// newest first, because that is the order the route publishes. Nothing here
    /// is sorted, filtered, deduplicated or synthesized.
    public internal(set) var events: [MeasurementReminderEvent] = []
    /// `data.meta` of the most recently accepted page — the page window the
    /// server actually applied, not the one that was asked for.
    public internal(set) var meta: MeasurementReminderHistoryPage.Meta?
    public internal(set) var isLoading = false
    /// The last failure, kept so the surface can offer a retry rather than a
    /// silently short page.
    public internal(set) var error: HLError?
    /// The route answered `404` for this reminder. An honest label, not an error.
    public internal(set) var isUnsupported = false

    /// `true` once one page has been accepted — the difference between "this
    /// reminder has no history" and "nobody has asked yet".
    public var isLoaded: Bool {
        meta != nil
    }

    /// Server truth: `meta.total` rows exist and `events.count` are held.
    public var hasMore: Bool {
        guard let meta else { return false }
        return events.count < meta.total
    }

    /// The offset the next page starts at. It is the number of rows already
    /// held, which is the server's own arithmetic: pages are requested from
    /// offset `0` upward and appended, so this is `meta.offset` plus the length
    /// of the page that carried it.
    var nextOffset: Int {
        events.count
    }
}

public extension MeasurementRemindersStore {
    /// The ledger held for a reminder — the "never asked" value when none is.
    func ledger(for id: String) -> MeasurementReminderLedger {
        ledgers[id] ?? MeasurementReminderLedger()
    }

    /// Whether an affordance for `action` may be offered on this reminder.
    ///
    /// `true` until the server has refused it with a `404`. The accepted DTO
    /// publishes nothing that identifies the one reminder family that refuses —
    /// appointment (encounter) reminders — so a locally-computed gate would be a
    /// capability iOS invented. Learning it from the refusal is the only honest
    /// gate the contract makes available.
    func supports(_ action: MeasurementReminderAction, id: String) -> Bool {
        !(unsupportedActions[id]?.contains(action) ?? false)
    }

    /// `POST …/{id}/skip` — honestly skip the current due cycle.
    ///
    /// Nothing is stamped locally: `lastSkippedAt`, `skipCount`, the restarted
    /// interval and the cleared snooze all arrive on the canonical row. A
    /// `skipped == false` answer is the idempotent no-op — the row is still the
    /// server's, so it is shown, not treated as a failure.
    @discardableResult
    func skip(id: String) async -> MeasurementReminderActionOutcome {
        guard reminders.contains(where: { $0.id == id }) else { return .failed(.unknown("unknown reminder")) }
        return await run(.skip, id: id) {
            let result = try await self.repo.skip(id: id)
            return (result.skipped, result.reminder)
        }
    }

    /// `POST …/{id}/snooze` — push the due date to a named calendar day.
    ///
    /// `day` is a `YYYY-MM-DD` string built with
    /// ``MeasurementReminderSnooze/day(_:in:)``; it is passed to the repository
    /// verbatim. The published bounds (at least tomorrow, at most five years
    /// out) are **not** enforced here — a client-side refusal would hide the
    /// server's `422`, which is where the contract put it.
    @discardableResult
    func snooze(id: String, until day: String) async -> MeasurementReminderActionOutcome {
        guard reminders.contains(where: { $0.id == id }) else { return .failed(.unknown("unknown reminder")) }
        return await run(.snooze, id: id) {
            try await (true, self.repo.snooze(id: id, until: day))
        }
    }

    /// `GET …/{id}/history` — one page of the completion ledger, appended.
    ///
    /// `reset` starts again at offset `0` (pull-to-refresh, or after an action
    /// wrote a row); otherwise the next page starts where the held rows end.
    /// `limit` is forwarded exactly as given and is never clamped — a value
    /// outside `1…100` is the server's `422`, and rewriting it here would hide
    /// the refusal. Omitting it gets the route's published default rather than a
    /// client-side guess at what that default is.
    ///
    /// A failure keeps every page already held: a short ledger with a retry is
    /// honest, an emptied one is not.
    func loadHistory(id: String, limit: Int? = nil, reset: Bool = false) async {
        let held = ledger(for: id)
        guard !held.isLoading, !held.isUnsupported else { return }
        var ledger = reset ? MeasurementReminderLedger() : held
        let offset = ledger.nextOffset
        ledger.isLoading = true
        ledger.error = nil
        ledgers[id] = ledger
        do {
            let page = try await repo.history(
                id: id,
                limit: limit,
                offset: offset == 0 ? nil : offset
            )
            var updated = ledgers[id] ?? ledger
            updated.events = (reset ? [] : updated.events) + page.events
            updated.meta = page.meta
            updated.isLoading = false
            updated.error = nil
            ledgers[id] = updated
        } catch {
            let failure = Self.asHLError(error)
            var updated = ledgers[id] ?? ledger
            updated.isLoading = false
            if Self.isCapabilityRefusal(failure) {
                updated.isUnsupported = true
                updated.error = nil
                withdraw(.history, id: id)
            } else {
                updated.error = failure
            }
            ledgers[id] = updated
        }
    }

    // MARK: - Shared action path

    /// Runs one reminder action with no optimistic mutation at all.
    ///
    /// The pre-call row is what stays on screen; `pendingAction` publishes that
    /// something is happening. Only the canonical row the accepted envelope
    /// carries replaces it, whole — the store never assembles a row, so it can
    /// never forget a field the DTO grew after this line was written.
    private func run(
        _ action: MeasurementReminderAction,
        id: String,
        call: () async throws -> (applied: Bool, reminder: MeasurementReminderRow)
    ) async -> MeasurementReminderActionOutcome {
        pendingAction[id] = action
        defer { pendingAction[id] = nil }
        do {
            let (applied, canonical) = try await call()
            if let index = reminders.firstIndex(where: { $0.id == id }) {
                reminders[index] = canonical
            }
            await writeThrough()
            error = nil
            // A satisfy, a complete and a skip each append a ledger row
            // server-side. A ledger already on screen is therefore stale — so it
            // is re-read authoritatively rather than guessed at. Nothing is
            // fetched for a reminder whose ledger was never opened.
            if ledgers[id] != nil {
                await loadHistory(id: id, reset: true)
            }
            return applied ? .applied : .noOp
        } catch {
            let failure = Self.asHLError(error)
            if Self.isCapabilityRefusal(failure) {
                withdraw(action, id: id)
                return .unsupported
            }
            self.error = failure
            return .failed(failure)
        }
    }

    /// A `404` on skip / snooze / history is the route saying "not for this
    /// reminder" — the appointment-reminder case the accepted descriptions name
    /// on all three routes. Every other status is a failure with a reason.
    private static func isCapabilityRefusal(_ error: HLError) -> Bool {
        if case .server(404, _, _) = error { return true }
        return false
    }

    private static func asHLError(_ error: Error) -> HLError {
        (error as? HLError) ?? .unknown(String(describing: error))
    }

    private func withdraw(_ action: MeasurementReminderAction, id: String) {
        unsupportedActions[id, default: []].insert(action)
    }
}
