import Foundation
import Observation

/// **Recently deleted (#151, server v1.46.0).** Backs
/// ``RecentlyDeletedDocumentsScreen``: the deleted documents the purge has not
/// removed yet, a restore that puts a row back into the vault list, and a
/// purge ahead of time after an in-place question.
///
/// Reads and writes run under the vault store's authenticated-session lease,
/// so a reply that lands after a logout or an account switch publishes
/// nothing. Every write that changes the vault (restore, purge) reloads the
/// vault store as well, which also refreshes `deletedCount` and therefore
/// the link on the list.
@MainActor
@Observable
final class DocumentsTrashStore {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed
        /// `403 module.disabled`: the documents module is off.
        case moduleOff
        /// Any other `403`: not offered here (somebody else's record).
        case notOffered
    }

    private(set) var phase: Phase = .loading
    private(set) var rows: [DeletedDocument] = []
    private(set) var graceDays: Int?
    /// The list cap from `meta`; `truncated` says the newest `limit` are shown.
    private(set) var cap: ListCapMeta?
    /// Rows with a restore or purge in flight.
    private(set) var busyIDs: Set<String> = []
    /// The row whose "delete for good" question is open, at most one.
    var confirmingPurgeID: String?
    /// The outcome of the last write that did not go through, in words.
    private(set) var outcome: String?

    @ObservationIgnored private let vault: DocumentsStore
    @ObservationIgnored private var generation: UInt64 = 0

    init(vault: DocumentsStore) {
        self.vault = vault
    }

    private var repository: DocumentsRepository {
        vault.repository
    }

    var isTruncated: Bool {
        cap?.truncated == true
    }

    // MARK: - Read

    func load() async {
        guard let lease = vault.captureAuthenticatedSessionLease() else { return }
        generation &+= 1
        let mine = generation
        if rows.isEmpty { phase = .loading }
        do {
            let page = try await repository.deletedDocuments()
            guard lease.isCurrent, mine == generation else { return }
            rows = page.data.documents
            graceDays = page.data.graceDays
            cap = page.cap
            phase = .loaded
            if let open = confirmingPurgeID, !rows.contains(where: { $0.id == open }) {
                confirmingPurgeID = nil
            }
        } catch {
            guard lease.isCurrent, mine == generation else { return }
            phase = Self.phase(for: error)
        }
    }

    nonisolated static func phase(for error: Error) -> Phase {
        if DocumentsRepository.isModuleDisabled(error) { return .moduleOff }
        if case HLError.server(403, _, _) = error { return .notOffered }
        return .failed
    }

    // MARK: - Writes

    /// `POST …/{id}/restore` through the vault store, which reloads the list
    /// so the document is back in it. `true` when restored.
    @discardableResult
    func restore(_ row: DeletedDocument) async -> Bool {
        guard !busyIDs.contains(row.id), let lease = vault.captureAuthenticatedSessionLease() else { return false }
        busyIDs.insert(row.id)
        defer { busyIDs.remove(row.id) }
        outcome = nil
        do {
            try await vault.restore(id: row.id)
            guard lease.isCurrent else { return false }
            rows.removeAll { $0.id == row.id }
            await load()
            return true
        } catch {
            guard lease.isCurrent else { return false }
            await refuse(error, purging: false)
            return false
        }
    }

    /// `POST …/{id}/purge` after the in-place question. `true` when removed.
    @discardableResult
    func purge(_ row: DeletedDocument) async -> Bool {
        guard !busyIDs.contains(row.id), let lease = vault.captureAuthenticatedSessionLease() else { return false }
        busyIDs.insert(row.id)
        defer { busyIDs.remove(row.id) }
        outcome = nil
        do {
            try await repository.purge(id: row.id)
            guard lease.isCurrent else { return false }
            confirmingPurgeID = nil
            rows.removeAll { $0.id == row.id }
            await vault.refreshUsage()
            await load()
            return true
        } catch {
            guard lease.isCurrent else { return false }
            confirmingPurgeID = nil
            await refuse(error, purging: true)
            return false
        }
    }

    func acknowledgeOutcome() {
        outcome = nil
    }

    /// Words a refused write. A row whose state moved on elsewhere (restored,
    /// purged, gone) is reloaded away; the vault list follows when it changed.
    private func refuse(_ error: Error, purging: Bool) async {
        let refusal = DocumentsRepository.trashRefusal(error, purging: purging)
        outcome = Self.message(for: refusal, purging: purging, error: error)
        switch refusal {
        case .notDeleted:
            await vault.load()
            await load()
        case .gone, .notFound:
            // A purge that finds nothing got what it asked for.
            if purging { outcome = nil }
            await vault.refreshUsage()
            await load()
        case .duplicateExists, nil:
            break
        }
    }

    nonisolated static func message(for refusal: DocumentTrashRefusal?, purging: Bool, error: Error) -> String {
        switch refusal {
        case .duplicateExists: String(localized: "documents.trash.restoreDuplicate")
        case .gone, .notFound: String(localized: "documents.error.purged")
        case .notDeleted: String(localized: "documents.trash.notDeleted")
        case nil:
            if case HLError.offline = error {
                HLError.offline.userFacingDescription
            } else if purging {
                String(localized: "documents.trash.purgeFailed")
            } else {
                String(localized: "documents.toast.restoreFailed")
            }
        }
    }
}
