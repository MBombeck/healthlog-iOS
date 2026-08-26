import Foundation
import Observation

public enum IllnessDayLogTimelineState: Sendable, Equatable {
    case loading
    case error
    case empty
    case loaded([IllnessDayLogDTO])
}

/// `@MainActor @Observable` store backing the native illness / condition-journal
/// surfaces (v1.18.1 `W-B`). Loads episodes + per-episode day-logs + the
/// server-computed correlation / insights via ``IllnessRepository``, and drives
/// optimistic episode add / resolve / delete.
///
/// **Default-ON (v1.18.3).** The surface is shown unless the user disabled the
/// module (`ModuleGate.isEnabled(.illness) == false`). A `403 illness.disabled`
/// flips ``isDisabled`` so the surface renders the re-enable / disabled state
/// instead of an error.
///
/// **Render-only derived.** The store NEVER recomputes a baseline, a deviation,
/// or a recovery gap. It pattern-matches `correlation.status` (`ok` → render
/// `value`; `insufficient` → render "still learning"). Correlation + insights
/// are tolerated DEFENSIVELY (empty / 404 / not-yet-deployed → a calm "not
/// enough data yet" state, never a crash).
///
/// **Delete-undo is lossless (v1.18.3).** The delete is an idempotent
/// soft-delete; undo calls `POST …/restore`, recovering the SAME episode id +
/// its day-logs + note intact. The optimistic delete still rolls back on a write
/// failure.
@MainActor
@Observable
public final class IllnessStore {
    public private(set) var episodes: [IllnessEpisodeDTO] = []
    public private(set) var selectedEpisode: IllnessEpisodeDTO?
    /// Day-logs for the selected episode, keyed by `YYYY-MM-DD`. Populated from
    /// the v1.18.3 list route on ``select(_:)`` (full history), then kept fresh
    /// by ``upsertDayLog(episodeId:_:)``. Sorted for display by the view.
    public private(set) var dayLogsByDate: [String: IllnessDayLogDTO] = [:]
    /// The server-computed `Derived<T>` for the selected episode, or `nil` while
    /// loading / unavailable.
    public private(set) var correlation: IllnessCorrelationDTO?
    public private(set) var insights: IllnessInsightsDTO?
    public private(set) var dayLogTimelineState: IllnessDayLogTimelineState = .empty

    public private(set) var isLoading = false
    public private(set) var isLoadingCorrelation = false
    /// True after a `403 illness.disabled` — the module is OFF (not opted in).
    public private(set) var isDisabled = false
    public private(set) var lastError: String?
    /// True when the last resolve failed because the episode is CHRONIC_ONGOING.
    public private(set) var lastErrorWasChronicNoResolve = false

    private let repository: IllnessRepository
    private let undo: UndoCoordinator?
    private var isReloading = false

    public init(repository: IllnessRepository, undo: UndoCoordinator? = nil) {
        self.repository = repository
        self.undo = undo
    }

    // MARK: - Derived helpers (computed; render helpers)

    /// True while at least one episode is open (unresolved) — drives the
    /// rest-mode annotation across the dashboard / recovery / streaks / coach
    /// (each gated by `isEnabled(.illness)` AND this flag).
    public var hasActiveEpisode: Bool {
        episodes.contains(where: \.isActive)
    }

    /// Active (unresolved) episodes, newest-first by onset (server order).
    public var activeEpisodes: [IllnessEpisodeDTO] {
        episodes.filter(\.isActive)
    }

    /// Resolved episodes, newest-first by onset (server order).
    public var resolvedEpisodes: [IllnessEpisodeDTO] {
        episodes.filter { !$0.isActive }
    }

    // MARK: - Load

    /// Load the episode list. No-op while a reload is already in flight. A `403
    /// illness.disabled` flips ``isDisabled``.
    public func load(includeResolved: Bool = true) async {
        guard !isReloading else { return }
        isReloading = true
        isLoading = true
        defer {
            isLoading = false
            isReloading = false
        }
        do {
            episodes = try await repository.episodes(includeResolved: includeResolved)
            isDisabled = false
            lastError = nil
        } catch {
            applyError(error)
        }
    }

    /// Load the cross-episode insights summary. Recovery-gap computation stays
    /// opt-in and is requested only by the dedicated analysis destination.
    public func loadInsights(
        windowDays: Int? = nil,
        includeRecoveryGap: Bool = false
    ) async {
        do {
            insights = try await repository.insights(
                windowDays: windowDays,
                includeRecoveryGap: includeRecoveryGap
            )
        } catch {
            if IllnessRepository.isIllnessDisabled(error) {
                applyError(error)
            } else {
                insights = nil
            }
        }
    }

    /// Select an episode + load its FULL day-log timeline (v1.18.3 list route) +
    /// the server-computed correlation. The correlation is tolerated defensively.
    public func select(_ episode: IllnessEpisodeDTO) async {
        selectedEpisode = episode
        correlation = nil
        // Clear FIRST so the timeline never shows a sibling episode's rows (QA
        // C-M1 cross-episode collision), then load the full history from the
        // v1.18.3 list endpoint (replacing the previous partial/empty timeline).
        dayLogsByDate = [:]
        await loadDayLogs(episodeId: episode.id)
        await loadCorrelation(episodeId: episode.id)
    }

    /// Load the episode's full day-log history and preserve honest presentation
    /// states: a request failure must never masquerade as an empty timeline.
    public func loadDayLogs(episodeId: String) async {
        dayLogsByDate = [:]
        dayLogTimelineState = .loading
        do {
            let list = try await repository.dayLogs(episodeId: episodeId)
            var map: [String: IllnessDayLogDTO] = [:]
            for log in list.dayLogs {
                map[log.date] = log
            }
            dayLogsByDate = map
            let sorted = map.values.sorted { $0.date > $1.date }
            dayLogTimelineState = sorted.isEmpty ? .empty : .loaded(sorted)
        } catch {
            if IllnessRepository.isIllnessDisabled(error) {
                applyError(error)
            } else {
                dayLogTimelineState = .error
            }
        }
    }

    /// Load the per-episode `Derived<T>` correlation. Tolerates empty / 404 /
    /// not-yet-deployed (leaves `correlation == nil` → "not enough data yet").
    public func loadCorrelation(episodeId: String) async {
        isLoadingCorrelation = true
        defer { isLoadingCorrelation = false }
        do {
            correlation = try await repository.correlation(episodeId: episodeId)
        } catch {
            if IllnessRepository.isIllnessDisabled(error) {
                applyError(error)
            } else {
                correlation = nil
            }
        }
    }

    /// Fetch the day-log for a date (pre-fills the log-day sheet). Returns `nil`
    /// when nothing is logged that day. Throws so the sheet can degrade.
    public func dayLog(episodeId: String, date: String) async throws -> IllnessDayLogDTO? {
        try await repository.dayLog(episodeId: episodeId, date: date)
    }

    // MARK: - Episode writes

    /// Create an episode, then reload. Returns the created episode on success.
    @discardableResult
    public func createEpisode(_ body: IllnessEpisodeCreate) async -> IllnessEpisodeDTO? {
        lastError = nil
        do {
            let created = try await repository.createEpisode(body)
            await load()
            return created
        } catch {
            applyError(error)
            return nil
        }
    }

    /// Update an episode, then reload. Returns `true` on success.
    @discardableResult
    public func updateEpisode(id: String, _ patch: IllnessEpisodePatch) async -> Bool {
        lastError = nil
        do {
            let updated = try await repository.updateEpisode(id: id, patch)
            if selectedEpisode?.id == id { selectedEpisode = updated }
            await load()
            return true
        } catch {
            applyError(error)
            return false
        }
    }

    /// Resolve an episode (`PATCH …/resolve`), then reload. Returns `true` on
    /// success. A CHRONIC_ONGOING episode 422s → ``lastErrorWasChronicNoResolve``.
    @discardableResult
    public func resolveEpisode(id: String, resolvedAt: String? = nil) async -> Bool {
        lastError = nil
        lastErrorWasChronicNoResolve = false
        do {
            let resolved = try await repository.resolveEpisode(id: id, resolvedAt: resolvedAt)
            if selectedEpisode?.id == id { selectedEpisode = resolved }
            await load()
            return true
        } catch {
            applyError(error)
            return false
        }
    }

    /// Optimistically remove an episode + surface a `HLUndoToast`. The episode is
    /// dropped from the in-memory list immediately; the server soft-delete fires
    /// in the background. Tapping undo calls `POST …/restore` (v1.18.3), which
    /// recovers the SAME id + its day-logs + note intact (lossless). Letting the
    /// window expire makes the deletion stand.
    public func deleteEpisode(_ episode: IllnessEpisodeDTO, undoMessage: String) async {
        lastError = nil
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        let removed = episodes.remove(at: index)

        undo?.enqueue(message: undoMessage) { [weak self] in
            await self?.restore(removed)
        }

        do {
            _ = try await repository.deleteEpisode(id: episode.id)
        } catch {
            // v0150 arch-L3 — the delete IS Outbox-backed: on a retriable failure
            // `IllnessRepository` durably enqueues the delete (it replays at
            // reachability) before re-throwing the typed error (the stale "no
            // Outbox path yet" note is gone). This store still rolls the
            // in-session optimistic removal back + drops the undo toast so the
            // user sees an honest "couldn't delete now" state; the queued replay
            // reconciles on reconnect (the soft-delete is tombstone-idempotent).
            if episodes.firstIndex(where: { $0.id == removed.id }) == nil {
                episodes.insert(removed, at: min(index, episodes.count))
            }
            undo?.dismiss(reason: .cancelled)
            applyError(error)
        }
    }

    /// Undo path for a deleted episode: `POST …/restore` recovers the SAME id +
    /// its day-logs + note intact (v1.18.3 — lossless, a pure `deletedAt` flip).
    /// Best-effort; on success the episode list is reloaded, on failure an error
    /// is surfaced.
    private func restore(_ episode: IllnessEpisodeDTO) async {
        lastError = nil
        do {
            _ = try await repository.restore(id: episode.id)
            await load()
        } catch {
            applyError(error)
        }
    }

    // MARK: - Day-log upsert

    /// Upsert a day-log for the selected episode, then refresh that day's cache.
    /// Returns `true` on success.
    @discardableResult
    public func upsertDayLog(episodeId: String, _ body: IllnessDayLogUpsert) async -> Bool {
        lastError = nil
        do {
            let stored = try await repository.upsertDayLog(episodeId: episodeId, body)
            dayLogsByDate[stored.date] = stored
            let sorted = dayLogsByDate.values.sorted { $0.date > $1.date }
            dayLogTimelineState = .loaded(sorted)
            return true
        } catch {
            applyError(error)
            return false
        }
    }

    // MARK: - Logout

    /// Drop every in-memory snapshot on logout so the next user never inherits
    /// the previous user's episodes.
    public func clearOnLogout() {
        episodes = []
        selectedEpisode = nil
        dayLogsByDate = [:]
        correlation = nil
        insights = nil
        dayLogTimelineState = .empty
        isLoading = false
        isLoadingCorrelation = false
        isReloading = false
        isDisabled = false
        lastError = nil
        lastErrorWasChronicNoResolve = false
    }

    /// Test-only — populate the in-memory episode + day-log snapshots without a
    /// network round-trip, so the logout-wipe suite can prove `clearOnLogout`
    /// purges the PHI. Production reaches this state only through ``load()`` /
    /// ``select(_:)``.
    func seedForTesting(
        episodes: [IllnessEpisodeDTO],
        selected: IllnessEpisodeDTO? = nil,
        dayLogsByDate: [String: IllnessDayLogDTO] = [:]
    ) {
        self.episodes = episodes
        selectedEpisode = selected
        self.dayLogsByDate = dayLogsByDate
        let sorted = dayLogsByDate.values.sorted { $0.date > $1.date }
        dayLogTimelineState = sorted.isEmpty ? .empty : .loaded(sorted)
    }

    // MARK: - Private

    private func applyError(_ error: Error) {
        if IllnessRepository.isIllnessDisabled(error) {
            isDisabled = true
            episodes = []
            selectedEpisode = nil
            dayLogsByDate = [:]
            correlation = nil
            insights = nil
            dayLogTimelineState = .empty
            lastError = nil
            lastErrorWasChronicNoResolve = false
            return
        }
        lastErrorWasChronicNoResolve = IllnessRepository.isChronicNoResolve(error)
        lastError = LogSanitizer.redact(String(describing: error))
    }
}
