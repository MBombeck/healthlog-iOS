import Foundation
import Observation

/// `@MainActor @Observable` store backing the user-defined custom-metric
/// surfaces. Loads the metric catalog via ``CustomMetricsRepository``, holds the
/// per-metric value feed for whichever detail page is open, and drives
/// optimistic delete with a `HLUndoToast` for the DEFINITION only.
///
/// **NOT gated.** Unlike ``LabsStore`` there is no `isDisabled` flag: the server
/// routes carry no module gate and `custom-metrics` is absent from the module
/// registry (verified in the route files — see ``CustomMetricsRepository``).
/// Inventing a local gate would hide a surface the server happily serves.
///
/// **Two different delete semantics, deliberately surfaced differently.**
/// Deleting a METRIC is a server soft-delete whose values survive and which a
/// same-name re-create revives, so the optimistic removal + undo pill is honest
/// (the undo re-creates the definition, which the server resolves to a revive).
/// Deleting a VALUE is a HARD delete with no restore endpoint — so that path
/// gets a destructive confirmation and NO undo promise.
@MainActor
@Observable
public final class CustomMetricsStore {
    /// The metric catalog, name-ordered as the server returns it. Each row
    /// carries `latest` + `entryCount`.
    public private(set) var metrics: [CustomMetricDTO] = []
    /// Values for the metric whose detail page is open, keyed by metric id.
    /// Newest-first. Only the open metric is populated — the catalog read is the
    /// app-wide snapshot, this is per-page working state.
    public private(set) var entriesByMetric: [String: [CustomMetricEntryDTO]] = [:]
    /// Server-reported total per metric (drives the honest "N values" count and
    /// the load-more affordance, which the client-side array length cannot give
    /// once paging starts).
    public private(set) var entryTotalByMetric: [String: Int] = [:]

    public private(set) var isLoading = false
    public private(set) var isLoadingEntries = false
    public private(set) var lastError: String?
    /// True when the last error was the duplicate-name `409`. The editor reads
    /// this to show an inline `HLFormErrorText` instead of a generic banner.
    public private(set) var lastErrorWasDuplicateName = false

    private let repository: CustomMetricsRepository
    private let undo: UndoCoordinator?
    /// In-flight guard so overlapping `load()` calls coalesce.
    private var isReloading = false

    /// Page size for the value feed. Matches the server's own `limit` cap
    /// (`listCustomMetricEntriesSchema`: `1...500`) so one page backs the full
    /// chart + history for any realistic metric, and `loadMoreEntries` only
    /// engages for genuinely long histories.
    public static let entriesPageSize = CustomMetricsRepository.entriesPageCap

    public init(repository: CustomMetricsRepository, undo: UndoCoordinator? = nil) {
        self.repository = repository
        self.undo = undo
    }

    // MARK: - Reads

    /// Load the metric catalog. Overlapping calls coalesce.
    public func load() async {
        guard !isReloading else { return }
        isReloading = true
        isLoading = true
        defer {
            isLoading = false
            isReloading = false
        }
        do {
            let response = try await repository.customMetrics()
            metrics = response.customMetrics
            lastError = nil
            lastErrorWasDuplicateName = false
        } catch {
            applyError(error)
        }
    }

    /// Load the first page of values for `metricID` (newest-first), replacing any
    /// previously held page for that metric.
    public func loadEntries(metricID: String) async {
        isLoadingEntries = true
        defer { isLoadingEntries = false }
        do {
            let response = try await repository.entries(
                metricID: metricID, limit: Self.entriesPageSize, offset: 0, sortDir: "desc"
            )
            entriesByMetric[metricID] = response.entries
            entryTotalByMetric[metricID] = response.meta.total
            lastError = nil
        } catch {
            applyError(error)
        }
    }

    /// Append the next page of values for `metricID`. No-op once the loaded
    /// count has reached the server-reported total.
    public func loadMoreEntries(metricID: String) async {
        let loaded = entriesByMetric[metricID]?.count ?? 0
        let total = entryTotalByMetric[metricID] ?? 0
        guard loaded < total, !isLoadingEntries else { return }
        isLoadingEntries = true
        defer { isLoadingEntries = false }
        do {
            let response = try await repository.entries(
                metricID: metricID, limit: Self.entriesPageSize, offset: loaded, sortDir: "desc"
            )
            entriesByMetric[metricID, default: []].append(contentsOf: response.entries)
            entryTotalByMetric[metricID] = response.meta.total
            lastError = nil
        } catch {
            applyError(error)
        }
    }

    /// The live definition for `id`, re-read from the catalog so an edit
    /// repaints every page bound to it.
    public func metric(id: String) -> CustomMetricDTO? {
        metrics.first { $0.id == id }
    }

    /// Values held for `metricID`, newest-first (empty when the page has not
    /// loaded yet).
    public func entries(for metricID: String) -> [CustomMetricEntryDTO] {
        entriesByMetric[metricID] ?? []
    }

    /// True when more values exist server-side than are currently loaded.
    public func hasMoreEntries(for metricID: String) -> Bool {
        (entriesByMetric[metricID]?.count ?? 0) < (entryTotalByMetric[metricID] ?? 0)
    }

    // MARK: - Definition writes

    /// Define a new metric. Returns `true` on success (INCLUDING an offline
    /// queue — see below).
    @discardableResult
    public func createMetric(_ body: CustomMetricCreate) async -> Bool {
        lastError = nil
        lastErrorWasDuplicateName = false
        do {
            _ = try await repository.createMetric(body)
            await load()
            return true
        } catch let err as HLError where err.shouldPersistToOutbox {
            // Offline-create-is-SUCCESS doctrine (audit H-2, as `LabsStore`
            // applies it): the repository durably enqueued the create under a
            // stable idempotency key. Reporting a failure would invite a re-tap
            // that mints a SECOND key → two metrics on reconnect, and the
            // `(userId, name)` unique index would turn the second into a 409 the
            // user never triggered. Insert an optimistic row and return success.
            metrics.append(Self.optimisticMetric(from: body))
            metrics.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            lastError = nil
            return true
        } catch {
            applyError(error)
            return false
        }
    }

    /// Edit a metric definition, then reload.
    @discardableResult
    public func updateMetric(id: String, _ patch: CustomMetricPatch) async -> Bool {
        lastError = nil
        lastErrorWasDuplicateName = false
        do {
            _ = try await repository.updateMetric(id: id, patch)
            await load()
            return true
        } catch {
            applyError(error)
            return false
        }
    }

    /// Optimistically remove a metric + surface a `HLUndoToast`.
    ///
    /// The server delete is SOFT and its values are retained, so undo re-creates
    /// the definition under the same name — which the server resolves to a
    /// REVIVE of the tombstoned row, history and all (`route.ts:100-135`). That
    /// is why this path can honestly promise an undo despite there being no
    /// restore endpoint.
    ///
    /// `undoMessage` is already-localized copy resolved by the caller (the
    /// `HLUndoToast` adoption contract).
    public func deleteMetric(id: String, undoMessage: String) async {
        lastError = nil
        guard let index = metrics.firstIndex(where: { $0.id == id }) else { return }
        let removed = metrics.remove(at: index)

        undo?.enqueue(message: undoMessage) { [weak self] in
            await self?.reviveMetric(removed)
        }

        do {
            try await repository.deleteMetric(id: id)
        } catch let err as HLError where err.shouldPersistToOutbox {
            // The delete is durably queued and WILL replay. Keep the optimistic
            // removal and the live undo affordance — rolling back here would make
            // the row reappear and vanish again after replay (a visible flicker).
            // Same doctrine as `LabsStore.deleteLab` (v0150 C-M3).
            applyError(err)
        } catch {
            // Permanent failure — restore the row and drop the undo so the user
            // sees an honest state rather than a silently vanished metric.
            if !metrics.contains(where: { $0.id == id }) {
                metrics.insert(removed, at: min(index, metrics.count))
            }
            undo?.dismiss(reason: .cancelled)
            applyError(error)
        }
    }

    /// Undo leg of ``deleteMetric(id:undoMessage:)`` — re-POST the definition so
    /// the server revives the tombstoned row (and its values) under the same name.
    @discardableResult
    private func reviveMetric(_ metric: CustomMetricDTO) async -> Bool {
        await createMetric(CustomMetricCreate(
            name: metric.name,
            unit: metric.unit,
            targetLow: metric.targetLow,
            targetHigh: metric.targetHigh,
            decimals: metric.decimals,
            description: metric.description,
            // CU-35 (3) — an undo restores the metric AS IT WAS, consent
            // included. Dropping the flag here would quietly revoke a choice the
            // user never revisited; re-asserting it would be equally wrong if it
            // was off. Carry the removed row's own value.
            correlationEnabled: metric.correlationEnabled
        ))
    }

    // MARK: - Value writes

    /// Log a value against `metricID`, then refresh both the value feed and the
    /// catalog (the catalog row embeds `latest` + `entryCount`).
    @discardableResult
    public func createEntry(metricID: String, _ body: CustomMetricEntryCreate) async -> Bool {
        lastError = nil
        do {
            _ = try await repository.createEntry(metricID: metricID, body)
            await loadEntries(metricID: metricID)
            await load()
            return true
        } catch let err as HLError where err.shouldPersistToOutbox {
            // Offline-log-is-SUCCESS, same reasoning as `createMetric`. The
            // optimistic row carries the DEFINITION's current unit, which is what
            // the server will snapshot when the queued write replays.
            let unit = metric(id: metricID)?.unit ?? ""
            let optimistic = Self.optimisticEntry(from: body, metricID: metricID, unit: unit)
            entriesByMetric[metricID, default: []].insert(optimistic, at: 0)
            entriesByMetric[metricID]?.sort { $0.measuredAt > $1.measuredAt }
            entryTotalByMetric[metricID] = (entryTotalByMetric[metricID] ?? 0) + 1
            lastError = nil
            return true
        } catch {
            applyError(error)
            return false
        }
    }

    /// Edit a logged value, then refresh the feed + catalog.
    @discardableResult
    public func updateEntry(
        metricID: String,
        entryID: String,
        _ patch: CustomMetricEntryPatch
    ) async -> Bool {
        lastError = nil
        do {
            _ = try await repository.updateEntry(metricID: metricID, entryID: entryID, patch)
            await loadEntries(metricID: metricID)
            await load()
            return true
        } catch {
            applyError(error)
            return false
        }
    }

    /// Delete a logged value. **HARD delete — no undo is offered**, because the
    /// server has no restore endpoint for an entry (unlike lab results). The
    /// caller must confirm destructively before calling this.
    @discardableResult
    public func deleteEntry(metricID: String, entryID: String) async -> Bool {
        lastError = nil
        let previous = entriesByMetric[metricID] ?? []
        entriesByMetric[metricID] = previous.filter { $0.id != entryID }
        entryTotalByMetric[metricID] = max(0, (entryTotalByMetric[metricID] ?? 0) - 1)
        do {
            try await repository.deleteEntry(metricID: metricID, entryID: entryID)
            await load()
            return true
        } catch let err as HLError where err.shouldPersistToOutbox {
            // Durably queued — keep the optimistic removal (it WILL replay).
            applyError(err)
            return true
        } catch {
            // Permanent failure — put the row back so the list stays honest.
            entriesByMetric[metricID] = previous
            entryTotalByMetric[metricID] = previous.count
            applyError(error)
            return false
        }
    }

    // MARK: - Logout

    /// Drop every in-memory snapshot on logout so the next user never inherits
    /// the previous user's metrics or values.
    public func clearOnLogout() {
        metrics = []
        entriesByMetric = [:]
        entryTotalByMetric = [:]
        isLoading = false
        isLoadingEntries = false
        isReloading = false
        lastError = nil
        lastErrorWasDuplicateName = false
    }

    /// Test-only — populate the in-memory snapshots without a network round-trip
    /// so the logout-wipe suite can prove `clearOnLogout` purges the PHI.
    func seedForTesting(
        metrics: [CustomMetricDTO],
        entries: [String: [CustomMetricEntryDTO]] = [:]
    ) {
        self.metrics = metrics
        entriesByMetric = entries
        entryTotalByMetric = entries.mapValues(\.count)
    }

    // MARK: - Private

    /// Optimistic in-memory definition for an offline-queued create. Carries a
    /// temporary `optimistic-…` id so it never collides with a server id — the
    /// same prefix `OutboxReplayService.resolveEntityId` keys the H-4 remap on.
    /// The next online `load()` replaces the whole snapshot.
    private static func optimisticMetric(from body: CustomMetricCreate) -> CustomMetricDTO {
        let now = ISO8601DateFormatter().string(from: Date.now)
        return CustomMetricDTO(
            id: "optimistic-\(UUID().uuidString)",
            name: body.name,
            unit: body.unit,
            targetLow: body.targetLow,
            targetHigh: body.targetHigh,
            decimals: body.decimals,
            description: body.description,
            correlationEnabled: body.correlationEnabled,
            createdAt: now,
            updatedAt: now,
            latest: nil,
            entryCount: 0
        )
    }

    /// Optimistic in-memory value for an offline-queued log. Same transient-
    /// placeholder contract as ``optimisticMetric(from:)``.
    private static func optimisticEntry(
        from body: CustomMetricEntryCreate,
        metricID: String,
        unit: String
    ) -> CustomMetricEntryDTO {
        CustomMetricEntryDTO(
            id: "optimistic-\(UUID().uuidString)",
            customMetricId: metricID,
            value: body.value,
            unit: unit,
            measuredAt: body.measuredAt,
            note: body.note,
            createdAt: ISO8601DateFormatter().string(from: Date.now)
        )
    }

    private func applyError(_ error: Error) {
        lastErrorWasDuplicateName = CustomMetricsRepository.isDuplicateName(error)
        lastError = LogSanitizer.redact(String(describing: error))
    }
}
