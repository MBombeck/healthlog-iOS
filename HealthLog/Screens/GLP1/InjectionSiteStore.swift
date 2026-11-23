import Foundation
import Observation

/// Backing store for the injection-site section.
///
/// **#169 (server 1.48.0): a site belongs to a dose.** The standalone "log a
/// site" flow is gone. A site is set on the last recorded injection through
/// `PUT …/intake/{eventId}` (``Glp1DoseChangeRepository/setInjectionSite(medicationID:intakeID:site:)``),
/// and a site logged on the device by an older build is offered for the
/// matching dose (``InjectionSiteOfferMatcher``) instead of being uploaded
/// blindly; the person confirms each one.
///
/// History and the rotation suggestion read the server's per-dose sites
/// (`PaginatedIntakeEvent.injectionSite`, passed in at load by
/// `MedicationDetailStore`) plus the device-only rows that are still there.
@MainActor
@Observable
public final class InjectionSiteStore {
    public let medicationID: String
    public private(set) var localSites: [InjectionSiteEntrySnapshot] = []
    public private(set) var serverIntakes: [PaginatedIntakeEvent] = []
    public private(set) var error: HLError?
    /// One plain sentence when the server refused a site for this
    /// medication (422 `medications.intake.injection_site.disallowed`). Shown
    /// in the section; such a write is never retried.
    public private(set) var notice: String?
    public private(set) var isLoading: Bool = false
    public private(set) var isSaving: Bool = false

    private let repo: GLP1LocalRepository
    private let historyLimit: Int
    /// Offers the server refused in this session; they are not offered again.
    private var refusedOffers: Set<String> = []

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
        self.serverIntakes = serverIntakes
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

    // MARK: - Site on a recorded dose

    /// The newest dose that was taken. `nil` before the first one.
    public var lastInjection: PaginatedIntakeEvent? {
        serverIntakes
            .filter { !$0.skipped && $0.takenAt != nil }
            .max { ($0.takenAt ?? .distantPast) < ($1.takenAt ?? .distantPast) }
    }

    /// The site recorded on the last dose, if any.
    public var lastInjectionSite: InjectionSite? {
        InjectionSite.parse(lastInjection?.injectionSite)
    }

    /// Whether a site can be set here: a server to write to and a dose to
    /// write it on.
    public var canSetSite: Bool {
        repo.doseChangeServer != nil && lastInjection != nil
    }

    /// Sets (`site`) or clears (`nil`) the site of the last injection.
    @discardableResult
    public func setSiteOnLastInjection(_ site: InjectionSite?) async -> Bool {
        guard let intake = lastInjection else { return false }
        return await write(site: site, intakeID: intake.id)
    }

    /// Device-only sites that fit a recorded dose, for the person to confirm.
    var offers: [InjectionSiteOfferMatcher.Offer] {
        guard repo.doseChangeServer != nil else { return [] }
        return InjectionSiteOfferMatcher.offers(
            medicationID: medicationID,
            localSites: localSites,
            intakes: serverIntakes
        )
        .filter { !refusedOffers.contains($0.id) }
    }

    /// Puts a device-only site on its dose. Once the server has it, the
    /// device copy goes.
    @discardableResult
    func apply(_ offer: InjectionSiteOfferMatcher.Offer) async -> Bool {
        let written = await write(site: offer.site, intakeID: offer.intakeID)
        if written {
            try? await repo.deleteSite(id: offer.localID)
            localSites.removeAll { $0.id == offer.localID }
        } else if notice != nil {
            refusedOffers.insert(offer.id)
        }
        return written
    }

    /// Deletes a device-only site. A failure lands in ``error`` for the banner.
    @discardableResult
    public func delete(id: String) async -> Bool {
        error = nil
        do {
            try await repo.deleteSite(id: id)
            localSites.removeAll { $0.id == id }
            return true
        } catch {
            self.error = PenInventoryStore.hlError(error)
            return false
        }
    }

    /// The one write. A refused site says so in ``notice`` and is not
    /// retried; a write waiting in the outbox counts as done.
    private func write(site: InjectionSite?, intakeID: String) async -> Bool {
        guard let server = repo.doseChangeServer, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        error = nil
        notice = nil
        do {
            try await server.setInjectionSite(medicationID: medicationID, intakeID: intakeID, site: site)
        } catch let err as HLError where err.isInjectionSiteDisallowed {
            notice = Self.disallowedSentence
            return false
        } catch let err as HLError where err.shouldPersistToOutbox {
            // Queued; it goes out with the next replay.
        } catch {
            self.error = PenInventoryStore.hlError(error)
            return false
        }
        replaceSite(of: intakeID, with: site)
        return true
    }

    private func replaceSite(of intakeID: String, with site: InjectionSite?) {
        guard let index = serverIntakes.firstIndex(where: { $0.id == intakeID }) else { return }
        let old = serverIntakes[index]
        serverIntakes[index] = PaginatedIntakeEvent(
            id: old.id,
            takenAt: old.takenAt,
            skipped: old.skipped,
            scheduledFor: old.scheduledFor,
            injectionSite: site?.serverRawValue,
            autoRecorded: old.autoRecorded
        )
    }

    static var disallowedSentence: String {
        String(
            localized: "glp1.site.disallowed",
            defaultValue: "This medication doesn't allow that site, so it wasn't saved."
        )
    }

    // MARK: - Derived data

    /// Newest-first history across the doses' sites and the device-only
    /// rows, capped at `historyLimit`.
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

    private var serverSites: [InjectionSiteRecord] {
        serverIntakes.compactMap { intake in
            guard let site = InjectionSite.parse(intake.injectionSite) else { return nil }
            return InjectionSiteRecord(
                id: "intake-\(intake.id)",
                when: intake.takenAt ?? intake.scheduledFor,
                site: site,
                source: .server
            )
        }
    }

    /// Most-recent site, regardless of source. Used as the "last used"
    /// label on the body map.
    public var lastUsedSite: InjectionSite? {
        mergedHistory.first?.site
    }

    /// Rotation-suggestion result via the pure-function helper. Returns
    /// `nil` for greenfield (no history).
    public var suggestedNextSite: InjectionSite? {
        InjectionSiteRotation.suggestNext(recent: mergedHistory.map(\.site))
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
