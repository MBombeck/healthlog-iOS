import Foundation
import Observation

@MainActor
@Observable
public final class MoodStore {
    public private(set) var entries: [MoodEntry] = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?

    /// **Phase 09 / plan 09-04 — the O(1) invalidation axis.**
    ///
    /// Advanced by every store mutation that actually changed the history, and
    /// by nothing else. The Mood analysis key carries this number instead of a
    /// hash of the entry array, so a SwiftUI body can decide "is this the same
    /// question I already answered?" in constant time on a 10,000-entry
    /// history. A revalidation that comes back with byte-identical entries is
    /// deliberately *not* a change: it must not throw away a resident analysis.
    public private(set) var entriesRevision: Int = 0

    /// The bounded, actor-owned analysis cache for this account's history. It
    /// is owned by the store — not a process-wide singleton — so both Mood
    /// hosts share one cache through the environment while nothing survives the
    /// store that produced it.
    @ObservationIgnored let analysisCache = MoodAnalysisCache()

    private let repo: MoodRepository
    private let healthKit: AnyHealthKitWriter?
    /// On-device AI tag-suggestion service (D-2). `nil` in older tests +
    /// pre-D-2 build configs — the screen surfaces no "Tags vorschlagen"
    /// affordance in that case. Injected by `AppContainer` so the same
    /// `MoodTagExtractionService` instance can be observed across the
    /// `MoodScreen` + `EditMoodSheet` surfaces (the actor itself is
    /// stateless, but sharing one instance keeps the live-flag closure
    /// allocation count down).
    private let tagExtraction: MoodTagExtractionService?
    /// Optional undo affordance — wired by the composition-root so a
    /// destructive `delete(_:)` enqueues a transient `Rückgängig`-pill.
    /// Stays `nil` in headless / unit-test contexts.
    private let undoCoordinator: UndoCoordinator?

    /// A2-M4 — appear-revalidation freshness gate (60s TTL).
    @ObservationIgnored private var revalidationGate = RevalidationGate(ttl: 60)

    /// **v0.10.0 W-Mood-B** — fired after `entries` change (load / log /
    /// update / delete) so the composition-root can refresh the mood widget
    /// glance. `nil` in headless / unit-test contexts; the composition-root
    /// wires it onto the `WidgetSnapshotWriter`. Synchronous + cheap (the
    /// closure reads the latest entry + writes one tiny JSON blob).
    public var onEntriesDidChange: (@MainActor () -> Void)?

    public init(
        repo: MoodRepository,
        healthKit: AnyHealthKitWriter? = nil,
        tagExtraction: MoodTagExtractionService? = nil,
        undoCoordinator: UndoCoordinator? = nil
    ) {
        self.repo = repo
        self.healthKit = healthKit
        self.tagExtraction = tagExtraction
        self.undoCoordinator = undoCoordinator
    }

    // MARK: - The one write path for `entries` (09-04)

    /// Assigns `entries` and advances ``entriesRevision`` — but only when the
    /// assignment actually changed the history.
    ///
    /// Every mutation in this store routes through here, which is what makes
    /// "the revision advanced" and "the analysis is stale" the same statement.
    /// The `!=` is O(n) with a tiny constant and runs once per user-driven
    /// mutation; the analysis it prevents re-running is O(n log n) with eight
    /// detectors behind it.
    private func publish(_ next: [MoodEntry]) {
        guard next != entries else { return }
        entries = next
        entriesRevision &+= 1
    }

    private func removeEntry(id: String) {
        var next = entries
        next.removeAll { $0.id == id }
        publish(next)
    }

    private func replaceEntry(at index: Int, with entry: MoodEntry) {
        var next = entries
        next[index] = entry
        publish(next)
    }

    private func insertEntry(_ entry: MoodEntry, at index: Int) {
        var next = entries
        next.insert(entry, at: index)
        publish(next)
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            // v0.4.0 charts marathon: the MoodScreen trend chart now exposes
            // a W/M/Q/J period picker, so the store needs the broadest
            // window upfront. We pull 365 days once and the view filters
            // client-side — server is happy (mood entries are small) and
            // the picker stays snappy (no re-fetch on toggle).
            try await publish(repo.recent(days: 365))
            onEntriesDidChange?()
            revalidationGate.markLoaded()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Fetch one filtered history page without mutating `entries`. Dashboard,
    /// widgets, and insights continue to observe the broad analytics snapshot.
    public func history(query: MoodHistoryQuery) async throws -> MoodListResponse {
        try await repo.history(query: query)
    }

    /// A2-M4 — appear-revalidation entry point: reload when empty (cold) OR
    /// stale (partial-then-stale), no-op inside the freshness window.
    public func revalidateIfStale() async {
        if entries.isEmpty || revalidationGate.isStale() {
            await load()
        }
    }

    public func clearOnLogout() {
        publish([])
        error = nil
        onEntriesDidChange?()
        // 09-04 — the revision bump above already makes every cached analysis
        // key unreachable, but an unreachable snapshot is still a resident one.
        // This drops the derived daily averages, tag names and correlation
        // sentences of the account that just signed out. It is synchronous by
        // design: this store is cleared from a registry loop that cannot await,
        // and a fire-and-forget purge would race the next composition.
        analysisCache.removeAll()
    }

    // MARK: - Derived accessors (B3 / v0.4.1)

    /// Latest mood entry recorded today (caller-locale day). `nil` if the user
    /// has not logged anything today yet. Used by the Mood-screen
    /// today-summary header to answer the question "did I log already?"
    /// without the user having to scroll to the chart for confirmation.
    public func todayEntry(now: Date = .now, calendar: Calendar = .current) -> MoodEntry? {
        entries.first { calendar.isDate($0.recordedAt, inSameDayAs: now) }
    }

    /// `count` most-recent entries sorted by `recordedAt` descending. The
    /// store always inserts new entries at index 0, so `Array(prefix:)`
    /// already gives the right order, but we re-sort defensively in case
    /// a future load path returns ascending data.
    public func recents(limit: Int) -> [MoodEntry] {
        let sorted = entries.sorted { $0.recordedAt > $1.recordedAt }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Total entry count in the loaded window — surfaced in the today-summary
    /// header ("24 Einträge insgesamt"). Snake-cased in the property name to
    /// stay consistent with the existing `entries` collection.
    public var totalCount: Int {
        entries.count
    }

    /// Number of mood entries recorded *today* (caller-locale day). The watch
    /// companion surfaces this as the quiet "N today" subhead so the wrist can
    /// log mood as many times as the user likes (multi-log), reconciling its
    /// optimistic local count against this authoritative phone count on the
    /// next pushed snapshot.
    public func todayCount(now: Date = .now, calendar: Calendar = .current) -> Int {
        entries.filter { calendar.isDate($0.recordedAt, inSameDayAs: now) }.count
    }

    // MARK: - Test support

    /// Test-only setter for `entries`. The public surface keeps `entries`
    /// `private(set)` — tests need a way to inject fixture data without
    /// hand-rolling a fake `MoodRepository`. Marked `internal` so
    /// `@testable import HealthLog` reaches it; production code does not
    /// see this method.
    func replaceEntriesForTesting(_ next: [MoodEntry]) {
        publish(next)
    }

    /// Optimistic delete — drops the entry immediately, restores on failure.
    ///
    /// **Undo (v0.5.5.1):** an optional `UndoCoordinator` surfaces a
    /// `Rückgängig`-pill that re-posts the entry via the standard `log`
    /// path. The re-post allocates a fresh server id; the original id is
    /// lost. On a non-retriable delete failure the optimistic remove
    /// rolls back and the toast is dismissed because the entry still
    /// lives server-side.
    public func delete(_ entry: MoodEntry) async -> Bool {
        let snapshot = entries
        let removed = entry
        removeEntry(id: entry.id)
        onEntriesDidChange?()
        undoCoordinator?.enqueue(
            message: String(localized: "undo.mood.removed")
        ) { [weak self] in
            await self?.restoreDeletedEntry(removed)
        }
        do {
            try await repo.delete(id: entry.id)
            // v0.10.0 W10 M1 — mirror the delete into Apple Health so a removed
            // mood doesn't linger in HKStateOfMind. Self-gated on the sync
            // toggle (no auth → swallowed no-op). Offline deletes propagate via
            // the outbox-replay path (`OutboxReplayService.deleteMood`).
            do {
                try await healthKit?.deleteMood(id: entry.id)
            } catch {
                HLLog.healthKit
                    .warning("HK-Mirror deleteMood fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
            return true
        } catch let err as HLError {
            error = err
            // A durably-enqueued DELETE (retriable OR a transient-refresh 401
            // the repo just queued) keeps the optimistic removal — the entry
            // is gone from the UI and the Outbox replays the DELETE. Leave the
            // undo affordance live. Only a dropped DELETE resurrects + dismisses.
            if !err.shouldPersistToOutbox {
                publish(snapshot)
                undoCoordinator?.dismiss(reason: .cancelled)
            }
            return false
        } catch {
            self.error = .unknown(String(describing: error))
            publish(snapshot)
            undoCoordinator?.dismiss(reason: .cancelled)
            return false
        }
    }

    /// Re-inserts a deleted mood entry locally and re-posts it through the
    /// standard `log` path. The new server row carries a fresh id; the
    /// original id is gone. Documented trade-off per the v0.5.5.1 undo
    /// brief.
    private func restoreDeletedEntry(_ entry: MoodEntry) async {
        removeEntry(id: entry.id)
        let insertIndex = entries.firstIndex { $0.recordedAt < entry.recordedAt } ?? entries.endIndex
        insertEntry(entry, at: insertIndex)
        _ = await log(score: entry.score, tags: entry.tags, tagKeys: entry.tagKeys, note: entry.note)
        // `log` inserts the fresh server row; drop the snapshot copy so
        // the list doesn't carry a duplicate.
        removeEntry(id: entry.id)
    }

    /// Optimistic update — swaps the entry immediately, restores on failure.
    /// `note` ist ab v1.4.30 ein dediziertes Feld; `tags` enthält keinen
    /// `"note:..."`-Eintrag mehr.
    /// `tagKeys` defaults to the entry's existing structured keys so a caller
    /// that only edits score/tags/note (e.g. the legacy edit sheet path) does
    /// not clobber the structured tag-links. Pass an explicit value to change
    /// them.
    public func update(
        _ entry: MoodEntry,
        score: Int,
        tags: [String],
        tagKeys: [String]? = nil,
        ratedFactors: [RatedFactorInput]? = nil,
        recordedAt: Date,
        note: String? = nil
    ) async -> Bool {
        let snapshot = entries
        let cleanTags = tags.filter { !$0.hasPrefix("note:") }
        let resolvedTagKeys = tagKeys ?? entry.tagKeys
        let optimistic = MoodEntry(
            id: entry.id,
            recordedAt: recordedAt,
            score: score,
            tags: cleanTags,
            tagKeys: resolvedTagKeys,
            note: note
        )
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            replaceEntry(at: i, with: optimistic)
        }
        onEntriesDidChange?()
        do {
            let saved = try await repo.update(
                id: entry.id,
                // Only send `tagKeys` when the caller passed one (else nil → the
                // server leaves the existing links untouched).
                patch: MoodEntryPatch(
                    score: score,
                    tags: cleanTags,
                    tagKeys: tagKeys,
                    ratedFactors: ratedFactors,
                    recordedAt: recordedAt,
                    note: note
                )
            )
            if let i = entries.firstIndex(where: { $0.id == entry.id }) {
                replaceEntry(at: i, with: saved)
            }
            onEntriesDidChange?()
            // v0.10.0 W-Mood-B — mirror edits into HKStateOfMind too (the
            // original write only mirrored on `log`). Anti-dupe via the same
            // externalUUID = server-id; HealthKit treats a re-save of the same
            // externalUUID as an update. Gated inside the writer (no-op when
            // the Apple-Health sync toggle / auth is off).
            do {
                try await healthKit?.writeMood(saved)
            } catch {
                HLLog.healthKit
                    .warning("HK-Mirror writeMood (edit) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
            return true
        } catch let err as HLError {
            error = err
            // A durably-enqueued PATCH (retriable OR a transient-refresh 401
            // the repo just queued) keeps the optimistic edit visible until
            // the Outbox replays — only a dropped write rolls back.
            if !err.shouldPersistToOutbox {
                publish(snapshot)
                onEntriesDidChange?()
            }
            return false
        } catch {
            self.error = .unknown(String(describing: error))
            publish(snapshot)
            onEntriesDidChange?()
            return false
        }
    }

    // MARK: - D-2 on-device tag suggestions

    /// True when the store has an extraction-service wired AND the device is
    /// at least iOS 26 (the runtime gate inside the service itself catches
    /// the rest). UI uses this to decide whether to render the "Tags
    /// vorschlagen" affordance at all — we don't want a dead button on
    /// older OS or builds without the service injected.
    public var supportsTagSuggestions: Bool {
        guard tagExtraction != nil else { return false }
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    /// Delegates to `MoodTagExtractionService.suggestTags(forNote:)`. Returns
    /// `nil` if the store wasn't constructed with an extraction service —
    /// surfaces should hide the affordance in that case.
    ///
    /// The call is feature-flag-gated inside the service (`.assistantTrend`).
    /// The MDR safety filter scrubs every suggestion before it reaches the
    /// caller. User-confirmation (tap-to-accept) remains the caller's
    /// responsibility — the store never auto-applies suggestions to the
    /// entry.
    public func suggestTags(
        forNote note: String,
        existingTags: [String] = [],
        locale: Locale = .current
    ) async -> MoodTagSuggestionOutcome? {
        guard let tagExtraction else { return nil }
        return await tagExtraction.suggestTags(
            forNote: note,
            existingTags: existingTags,
            locale: locale
        )
    }

    /// Logs a mood entry. Always **appends** (never overwrites) — the
    /// v0.6.1.15 Y10 redesign treats every tap as a discrete check-in,
    /// so the operator can record multiple moods per day (e.g. morning
    /// + evening). The optional `recordedAt` lets the screen back-date
    /// an entry up to 14 days when the operator uses the date picker;
    /// callers that pass `nil` get the legacy `.now` stamp.
    @discardableResult
    public func log(score: Int, tags: [String], tagKeys: [String] = [], note: String?, recordedAt: Date? = nil) async -> Bool {
        await logReturningEntry(score: score, tags: tags, tagKeys: tagKeys, note: note, recordedAt: recordedAt) != nil
    }

    /// Entry-returning variant of ``log(score:tags:note:recordedAt:)``.
    /// Returns the persisted (or optimistic-on-`.queued`) `MoodEntry` so the
    /// undo path (v0.11 W26) can target the just-logged row for removal.
    /// Returns `nil` only when a non-retriable failure rolled the optimistic
    /// insert back (nothing landed).
    public func logReturningEntry(
        score: Int,
        tags: [String],
        tagKeys: [String] = [],
        note: String?,
        recordedAt: Date? = nil
    ) async -> MoodEntry? {
        await logReturningOutcome(score: score, tags: tags, tagKeys: tagKeys, note: note, recordedAt: recordedAt).entry
    }

    /// The honest result of a mood log: the persisted-or-optimistic entry (or
    /// `nil` when nothing landed) plus a tri-state ``MedicationsStore/WriteOutcome``
    /// the caller can surface (WW/F2: the watch needs to distinguish "saved" /
    /// "saved, will sync" / "couldn't save").
    public struct MoodLogResult: Sendable {
        public let entry: MoodEntry?
        public let outcome: MedicationsStore.WriteOutcome
    }

    /// Outcome-returning variant of ``logReturningEntry``. Single source of
    /// truth for the optimistic-insert / repo-call / rollback dance.
    public func logReturningOutcome(
        score: Int,
        tags: [String],
        tagKeys: [String] = [],
        note: String?,
        recordedAt: Date? = nil
    ) async -> MoodLogResult {
        // Optimistic insert mit lokal-temporärer ID — Repo enqueued Outbox bei
        // `shouldPersistToOutbox`-Fehlern (retriable + `.unauthorized`).
        let stamp = recordedAt ?? .now
        let local = MoodEntry(id: "local-\(UUID().uuidString)", recordedAt: stamp, score: score, tags: tags, tagKeys: tagKeys, note: note)
        insertEntry(local, at: 0)
        onEntriesDidChange?()
        do {
            let saved = try await repo.log(score: score, tags: tags, tagKeys: tagKeys, note: note, recordedAt: recordedAt)
            if let i = entries.firstIndex(where: { $0.id == local.id }) {
                replaceEntry(at: i, with: saved)
            }
            // Bidirectional HK mirror: write to HKStateOfMindSample with
            // externalUUID = server-id so a future read-back skips dup.
            do {
                try await healthKit?.writeMood(saved)
            } catch {
                HLLog.healthKit
                    .warning("HK-Mirror writeMood (log) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
            return MoodLogResult(entry: saved, outcome: .success)
        } catch let err as HLError {
            error = err
            // WC/D1 + WW/F1: the repo enqueues to the Outbox for everything
            // `shouldPersistToOutbox` covers (retriable PLUS `.unauthorized`).
            // Gating the keep-optimistic-row decision on `isRetriable` here
            // DROPPED a 401-queued write from the UI even though it survived in
            // the Outbox — the exact watch-mood-vanishes bug. Keep the row +
            // report `.queued` for all of those.
            if err.shouldPersistToOutbox {
                // Optimistic row stays, outbox replays. Hand the local row back
                // so undo can still target it (the delete path is outbox-aware).
                return MoodLogResult(entry: local, outcome: .queued)
            }
            removeEntry(id: local.id)
            return MoodLogResult(entry: nil, outcome: .failed(err))
        } catch {
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            removeEntry(id: local.id)
            return MoodLogResult(entry: nil, outcome: .failed(wrapped))
        }
    }

    /// v0.11 W26 — quick-entry mood log with an undo affordance. Logs the
    /// score (no tags / note — the fast face-tap path) and, on a landed
    /// write, enqueues a `Rückgängig` toast whose closure removes the
    /// just-logged entry. Removal routes through the standard ``delete(_:)``
    /// path (server DELETE + HK-mirror purge + outbox on offline) but
    /// suppresses delete's own counter-undo so the toast doesn't chain.
    /// Returns the saved entry (or `nil` if nothing landed).
    @discardableResult
    public func logUndoable(score: Int, recordedAt: Date? = nil) async -> MoodEntry? {
        guard let saved = await logReturningEntry(
            score: score, tags: [], note: nil, recordedAt: recordedAt
        ) else { return nil }
        undoCoordinator?.enqueue(
            message: String(localized: "undo.mood.logged")
        ) { [weak self] in
            await self?.removeLoggedEntry(saved)
        }
        return saved
    }

    /// Undo of a quick log — removes the entry locally + server-side without
    /// enqueueing a counter-undo (so the toast doesn't offer "undo the
    /// undo"). Mirrors ``delete(_:)``'s server + HK-mirror teardown.
    private func removeLoggedEntry(_ entry: MoodEntry) async {
        let snapshot = entries
        removeEntry(id: entry.id)
        onEntriesDidChange?()
        do {
            try await repo.delete(id: entry.id)
            do {
                try await healthKit?.deleteMood(id: entry.id)
            } catch {
                HLLog.healthKit
                    .warning("HK-Mirror deleteMood (undo log) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        } catch let err as HLError {
            error = err
            // The undo-DELETE is durably enqueued for a retriable error or a
            // transient-refresh 401 — keep the entry removed (the user undid
            // the log) and let the Outbox replay. Only a dropped DELETE
            // resurrects the entry.
            if !err.shouldPersistToOutbox {
                publish(snapshot)
                onEntriesDidChange?()
            }
        } catch {
            self.error = .unknown(String(describing: error))
            publish(snapshot)
            onEntriesDidChange?()
        }
    }
}
