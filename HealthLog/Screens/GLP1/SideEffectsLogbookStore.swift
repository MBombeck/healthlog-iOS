import Foundation
import Observation

/// Backing store for the side-effects logbook section.
///
/// **v0.12 SP3 — server round-trip.** The local `GLP1LocalRepository` is the
/// optimistic on-device cache (instant render, offline-safe). When a server
/// pairing exists (`serverRepo != nil`), every create/delete is *also* mirrored
/// to `…/medications/[id]/side-effects` through the Outbox + idempotency-key
/// pipeline (`MedicationTherapyLogRepository`): the server write is attempted,
/// and on a retriable failure it lands in the Outbox and replays on
/// reachability + foreground. On 2xx the Outbox entry clears. The server row id
/// is back-written onto the local row so subsequent deletes target the right
/// server log. **Standalone** (no pairing → `serverRepo == nil`) stays purely
/// local: nothing is enqueued, nothing replays. Default query window is 90 days.
@MainActor
@Observable
public final class SideEffectsLogbookStore {
    public let medicationID: String
    public private(set) var entries: [SideEffectEntrySnapshot] = []
    public private(set) var error: HLError?
    public private(set) var isLoading: Bool = false

    private let repo: GLP1LocalRepository
    /// v0.12 SP3 — `nil` in standalone (no server). Non-nil → mirror writes +
    /// hydrate reads from the server.
    private let serverRepo: MedicationTherapyLogRepository?
    private let windowDays: Int

    public init(
        medicationID: String,
        repo: GLP1LocalRepository,
        serverRepo: MedicationTherapyLogRepository? = nil,
        windowDays: Int = 90
    ) {
        self.medicationID = medicationID
        self.repo = repo
        self.serverRepo = serverRepo
        self.windowDays = windowDays
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            // SWR: paint the local cache first.
            entries = try await repo.sideEffects(
                medicationID: medicationID,
                sinceDays: windowDays
            )
            // Paired: reconcile against the server (cache-first, then refresh).
            if let serverRepo {
                let remote = try await serverRepo.sideEffects(
                    medicationID: medicationID, sinceDays: windowDays
                )
                entries = reconcile(local: entries, remote: remote)
            }
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func log(
        loggedAt: Date,
        kind: SideEffectKind,
        severity: Int,
        note: String?
    ) async {
        do {
            // Optimistic local write (instant + offline-safe).
            let inserted = try await repo.addSideEffect(
                medicationID: medicationID,
                loggedAt: loggedAt,
                kind: kind,
                severity: severity,
                note: note
            )
            entries = mergeSortedDescending(existing: entries, inserted: inserted)
            // Mirror to the server when paired (Outbox-on-failure inside the repo).
            if let serverRepo {
                let body = MedicationSideEffectCreate(
                    entry: kind.serverEntry,
                    severity: SideEffectSeverityBridge.toServer(severity),
                    occurredAt: loggedAt,
                    notes: note
                )
                // A retriable error already enqueued on the Outbox — the local
                // row stands and the server write replays. Non-retriable errors
                // surface so the user sees a genuine failure.
                do {
                    let created = try await serverRepo.createSideEffect(medicationID: medicationID, body: body)
                    try? await repo.setSideEffectServerID(localID: inserted.id, serverID: created.id)
                } catch let err as HLError where err.shouldPersistToOutbox {
                    // Queued for replay (incl. a transient-refresh 401 the
                    // repo durably enqueued) — keep the optimistic row, no banner.
                }
            }
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func delete(id: String) async {
        do {
            // Resolve the server id (if this row was mirrored) before the local
            // delete drops the mapping.
            let serverID = try? await repo.sideEffectServerID(localID: id)
            try await repo.deleteSideEffect(id: id)
            entries.removeAll { $0.id == id }
            if let serverRepo, let serverID {
                do {
                    try await serverRepo.deleteSideEffect(medicationID: medicationID, logID: serverID)
                } catch let err as HLError where err.shouldPersistToOutbox {
                    // Queued for replay (incl. a transient-refresh 401) — no banner.
                }
            }
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Reconcile the local cache with the server truth. Server rows the local
    /// store hasn't mirrored yet (e.g. created on web/another device) are merged
    /// in; rows already mirrored (same server id) are deduped on the local copy.
    private func reconcile(
        local: [SideEffectEntrySnapshot],
        remote: [MedicationSideEffectDTO]
    ) -> [SideEffectEntrySnapshot] {
        let knownServerIDs = Set(local.compactMap(\.serverID))
        var merged = local
        for row in remote where !knownServerIDs.contains(row.id) {
            merged.append(
                SideEffectEntrySnapshot(
                    id: row.id,
                    medicationID: medicationID,
                    loggedAt: row.occurredAt,
                    kindRaw: (SideEffectKind.from(serverEntry: row.entry) ?? .nausea).rawValue,
                    severity: SideEffectSeverityBridge.toLocal(row.severity),
                    note: row.notes,
                    createdAt: row.createdAt ?? row.occurredAt,
                    serverID: row.id
                )
            )
        }
        merged.sort { $0.loggedAt > $1.loggedAt }
        return merged
    }

    // MARK: - Derived data

    /// Per-kind aggregate row used by the summary chips.
    public struct SummaryRow: Sendable, Hashable, Identifiable {
        public let kind: SideEffectKind
        public let count: Int
        public let weight: Int
        public var id: SideEffectKind {
            kind
        }
    }

    /// Per-day group used by the logbook list.
    public struct DayGroup: Sendable, Hashable, Identifiable {
        public let day: Date
        public let rows: [SideEffectEntrySnapshot]
        public var id: Date {
            day
        }
    }

    /// Returns the per-kind aggregate over the loaded window. Used by the
    /// summary chips above the daily list to surface the dominant tone of
    /// recent intakes (e.g. "Übelkeit · 3× in 7 Tagen"). Severity-weighted:
    /// row severity is summed per kind so a single severe row outranks
    /// three mild ones. Result is sorted by descending weight; only kinds
    /// with at least one row appear.
    public var summaryByKind: [SummaryRow] {
        var counts: [SideEffectKind: (count: Int, weight: Int)] = [:]
        for entry in entries {
            guard let kind = entry.kind else { continue }
            let prev = counts[kind] ?? (0, 0)
            counts[kind] = (prev.count + 1, prev.weight + max(1, entry.severity))
        }
        return counts
            .map { SummaryRow(kind: $0.key, count: $0.value.count, weight: $0.value.weight) }
            .sorted { $0.weight > $1.weight }
    }

    /// Entries bucketed by calendar day (newest-day-first). Used by the
    /// per-day list renderer so the section can group "today / yesterday
    /// / earlier" without per-row date headers.
    public var entriesByDay: [DayGroup] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.loggedAt)
        }
        return buckets
            .map { DayGroup(day: $0.key, rows: $0.value.sorted { $0.loggedAt > $1.loggedAt }) }
            .sorted { $0.day > $1.day }
    }

    // MARK: - Internals

    private func mergeSortedDescending(
        existing: [SideEffectEntrySnapshot],
        inserted: SideEffectEntrySnapshot
    ) -> [SideEffectEntrySnapshot] {
        var merged = existing
        merged.append(inserted)
        merged.sort { $0.loggedAt > $1.loggedAt }
        return merged
    }
}
