import Foundation
import Observation

/// Backing store for the injection-site picker section.
///
/// Reads local `InjectionSiteEntry` rows from `GLP1LocalRepository`
/// **plus** server-side per-intake injection sites from the
/// `PaginatedIntakeEvent.injectionSite` field (passed in at load via
/// `MedicationDetailStore`). The union feeds the rotation-suggestion
/// algorithm so both data sources count toward the "least-used in
/// window" calculation.
@MainActor
@Observable
public final class InjectionSiteStore {
    public let medicationID: String
    public private(set) var localSites: [InjectionSiteEntrySnapshot] = []
    public private(set) var serverSites: [InjectionSiteRecord] = []
    public private(set) var error: HLError?
    public private(set) var isLoading: Bool = false

    private let repo: GLP1LocalRepository
    private let historyLimit: Int

    public init(
        medicationID: String,
        repo: GLP1LocalRepository,
        historyLimit: Int = 24
    ) {
        self.medicationID = medicationID
        self.repo = repo
        self.historyLimit = historyLimit
    }

    public func load(serverIntakes: [PaginatedIntakeEvent]) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        serverSites = serverIntakes.compactMap { intake in
            guard let site = InjectionSite.parse(intake.injectionSite),
                  let when = intake.takenAt ?? Optional(intake.scheduledFor) else { return nil }
            return InjectionSiteRecord(when: when, site: site, source: .server)
        }
        do {
            localSites = try await repo.sites(
                medicationID: medicationID,
                limit: historyLimit
            )
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func log(site: InjectionSite, injectedAt: Date = .now, note: String? = nil) async {
        do {
            let inserted = try await repo.addSite(
                medicationID: medicationID,
                injectedAt: injectedAt,
                site: site,
                note: note
            )
            localSites = mergeSortedDescending(existing: localSites, inserted: inserted)
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func delete(id: String) async {
        do {
            try await repo.deleteSite(id: id)
            localSites.removeAll { $0.id == id }
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    // MARK: - Derived data

    /// Newest-first merged history across local + server records, capped
    /// at `historyLimit`.
    public var mergedHistory: [InjectionSiteRecord] {
        var combined = localSites.compactMap { snapshot -> InjectionSiteRecord? in
            guard let site = snapshot.site else { return nil }
            return InjectionSiteRecord(
                id: snapshot.id,
                when: snapshot.injectedAt,
                site: site,
                source: .local
            )
        }
        combined.append(contentsOf: serverSites)
        combined.sort { $0.when > $1.when }
        return Array(combined.prefix(historyLimit))
    }

    /// Most-recent site, regardless of source. Used as the "last used"
    /// label on the picker.
    public var lastUsedSite: InjectionSite? {
        mergedHistory.first?.site
    }

    /// Rotation-suggestion result via the pure-function helper. Returns
    /// `nil` for greenfield (no history).
    public var suggestedNextSite: InjectionSite? {
        InjectionSiteRotation.suggestNext(recent: mergedHistory.map(\.site))
    }

    // MARK: - Internals

    private func mergeSortedDescending(
        existing: [InjectionSiteEntrySnapshot],
        inserted: InjectionSiteEntrySnapshot
    ) -> [InjectionSiteEntrySnapshot] {
        var merged = existing
        merged.append(inserted)
        merged.sort { $0.injectedAt > $1.injectedAt }
        return merged
    }
}

/// Sendable record used by `InjectionSiteStore` for the merged-history
/// view. Carries the source (server vs local) so the row renderer can
/// hide the delete action on server rows.
public struct InjectionSiteRecord: Sendable, Hashable, Identifiable {
    public enum Source: Sendable {
        case local
        case server
    }

    public let id: String
    public let when: Date
    public let site: InjectionSite
    public let source: Source

    init(id: String = UUID().uuidString, when: Date, site: InjectionSite, source: Source) {
        self.id = id
        self.when = when
        self.site = site
        self.source = source
    }
}
