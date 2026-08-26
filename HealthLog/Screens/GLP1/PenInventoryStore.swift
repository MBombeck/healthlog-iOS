import Foundation
import Observation

/// Backing store for the pen-inventory section.
///
/// **v0.12 SP4 — server round-trip.** `GLP1LocalRepository` is the optimistic
/// on-device cache; when a server pairing exists (`serverRepo != nil`) every
/// add / mark-finished / delete is *also* mirrored to
/// `…/medications/[id]/inventory` through the Outbox + idempotency-key pipeline
/// (`MedicationTherapyLogRepository`). The authoritative running-low math +
/// state machine live server-side; iOS posts the user intent and reconciles the
/// computed rows on load. **Standalone** (no pairing → `serverRepo == nil`)
/// stays purely local: nothing is enqueued, nothing replays.
@MainActor
@Observable
public final class PenInventoryStore {
    public let medicationID: String
    public private(set) var pens: [PenInventoryEntrySnapshot] = []
    public private(set) var error: HLError?
    public private(set) var isLoading: Bool = false

    private let repo: GLP1LocalRepository
    private let serverRepo: MedicationTherapyLogRepository?

    /// Default doses-per-pen when the local UI does not capture a count. A
    /// standard GLP-1 weekly pen carries four weekly doses; the server clamps
    /// 1–100, and the user can correct it on the web/detail screen.
    private static let defaultDosesPerPen = 4

    public init(
        medicationID: String,
        repo: GLP1LocalRepository,
        serverRepo: MedicationTherapyLogRepository? = nil
    ) {
        self.medicationID = medicationID
        self.repo = repo
        self.serverRepo = serverRepo
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            pens = try await repo.pens(medicationID: medicationID)
            // **#52 — back-fill from the server (v1.31.0).** The reason the
            // back-fill was skipped in v0.12 is gone: `MedicationInventoryItem`
            // carries `manufacturer` + `doseStrength` since migration 0256, so a
            // pen registered on the web is a complete pen row, not a blank card.
            // A row that carries neither field is NOT a pen entry (a tablet pack
            // registered in the generic "Bestand" section) and is skipped —
            // fabricating empty cards is worse than showing nothing.
            //
            // Failures are swallowed (offline → the local list stands).
            if let serverRepo, let rows = try? await serverRepo.inventory(medicationID: medicationID) {
                await backfill(from: rows)
            }
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func add(
        manufacturer: String,
        doseStrength: String,
        dispensedAt: Date,
        firstUsedAt: Date?,
        notes: String?
    ) async {
        do {
            let inserted = try await repo.addPen(
                medicationID: medicationID,
                manufacturer: manufacturer,
                doseStrength: doseStrength,
                dispensedAt: dispensedAt,
                firstUsedAt: firstUsedAt,
                notes: notes
            )
            pens = mergeSortedDescending(existing: pens, inserted: inserted)
            if let serverRepo {
                // #52 — the pen detail travels to the server (v1.31.0) instead of
                // staying device-local, so the same pen renders on the web.
                let body = MedicationInventoryCreate(
                    unitsTotal: Double(Self.defaultDosesPerPen),
                    containerType: .pen,
                    manufacturer: manufacturer,
                    doseStrength: doseStrength,
                    printedExpiry: nil,
                    purchasedAt: dispensedAt,
                    notes: notes
                )
                do {
                    let created = try await serverRepo.createInventoryItem(medicationID: medicationID, body: body)
                    try? await repo.setPenServerID(localID: inserted.id, serverID: created.id)
                    // If the pen was logged as already-started, sync first-use.
                    if let firstUsedAt {
                        _ = try? await serverRepo.updateInventoryItem(
                            medicationID: medicationID,
                            itemID: created.id,
                            patch: MedicationInventoryPatch(markAsFirstUseAt: .set(firstUsedAt))
                        )
                    }
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

    public func markFinished(id: String) async {
        do {
            let serverID = try? await repo.penServerID(localID: id)
            try await repo.markPenFinished(id: id, finishedAt: .now)
            pens = try await repo.pens(medicationID: medicationID)
            if let serverRepo, let serverID {
                do {
                    _ = try await serverRepo.updateInventoryItem(
                        medicationID: medicationID,
                        itemID: serverID,
                        patch: MedicationInventoryPatch(markAsUsedUp: true)
                    )
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

    public func delete(id: String) async {
        do {
            let serverID = try? await repo.penServerID(localID: id)
            try await repo.deletePen(id: id)
            pens.removeAll { $0.id == id }
            if let serverRepo, let serverID {
                do {
                    try await serverRepo.deleteInventoryItem(medicationID: medicationID, itemID: serverID)
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

    // MARK: - Server back-fill (#52)

    /// The pen detail carried by a server inventory row, or `nil` when the row is
    /// not a pen entry at all.
    ///
    /// A generic container (a tablet pack registered in the "Bestand" section)
    /// carries neither `manufacturer` nor `doseStrength`; replaying it here would
    /// fabricate a blank pen card. One populated field is enough to qualify — the
    /// view omits the half that is missing rather than rendering an empty line.
    /// `nonisolated static` so the classification is unit-testable off the actor.
    nonisolated static func penDetail(
        from row: MedicationInventoryItemDTO
    ) -> (manufacturer: String, doseStrength: String)? {
        let manufacturer = row.manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let doseStrength = row.doseStrength?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !manufacturer.isEmpty || !doseStrength.isEmpty else { return nil }
        return (manufacturer, doseStrength)
    }

    /// Replay the qualifying server rows into the local pen list, then re-read.
    /// Insert-or-update is keyed on the server id, so a pen opened or used up on
    /// the web converges here instead of duplicating.
    private func backfill(from rows: [MedicationInventoryItemDTO]) async {
        var changed = false
        for row in rows {
            guard let detail = Self.penDetail(from: row) else { continue }
            let dispensedAt = InventorySanity.validDate(row.purchasedAt)
                ?? InventorySanity.validDate(row.createdAt)
                ?? InventorySanity.validDate(row.firstUseAt)
                ?? .now
            let finishedAt = row.state == "USED_UP"
                ? (InventorySanity.validDate(row.updatedAt) ?? .now)
                : nil
            do {
                try await repo.upsertPenFromServer(
                    serverID: row.id,
                    medicationID: medicationID,
                    manufacturer: detail.manufacturer,
                    doseStrength: detail.doseStrength,
                    dispensedAt: dispensedAt,
                    firstUsedAt: InventorySanity.validDate(row.firstUseAt),
                    finishedAt: finishedAt,
                    notes: row.notes
                )
                changed = true
            } catch {
                // One unwritable row must not sink the rest of the back-fill.
                continue
            }
        }
        guard changed else { return }
        let refreshed = try? await repo.pens(medicationID: medicationID)
        pens = refreshed ?? pens
    }

    // MARK: - Derived data

    /// Currently active pen — first non-finished row with a firstUsedAt
    /// timestamp. Used by the section header to surface "Aktuell in
    /// Gebrauch".
    public var activePen: PenInventoryEntrySnapshot? {
        pens.first { $0.isActive }
    }

    /// Pens that are still unopened (in stock) — used by the "Vorrat"
    /// summary line.
    public var unopenedCount: Int {
        pens.filter { !$0.isActive && !$0.isFinished }.count
    }

    /// Pens marked as finished — used by the history block.
    public var finishedPens: [PenInventoryEntrySnapshot] {
        pens.filter(\.isFinished)
    }

    // MARK: - Internals

    private func mergeSortedDescending(
        existing: [PenInventoryEntrySnapshot],
        inserted: PenInventoryEntrySnapshot
    ) -> [PenInventoryEntrySnapshot] {
        var merged = existing
        merged.append(inserted)
        merged.sort { $0.dispensedAt > $1.dispensedAt }
        return merged
    }
}
