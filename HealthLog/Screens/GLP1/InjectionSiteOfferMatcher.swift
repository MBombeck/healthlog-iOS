import Foundation

/// **#169 — which recorded dose an older, device-only site belongs to.**
///
/// Before 1.8 a site could be logged on its own, next to the dose, and it
/// stayed on the device. Such a row is not uploaded blindly: it is offered for
/// a recorded dose of the same medication, taken within a few hours of it,
/// that has no site yet, and the person confirms. Pure, so the rule is tested
/// on its own.
enum InjectionSiteOfferMatcher {
    /// How far apart a logged site and a taken dose may be.
    static let window: TimeInterval = 4 * 60 * 60

    /// One proposal: put `site` on the dose `intakeID`.
    struct Offer: Hashable, Identifiable, Sendable {
        let localID: String
        let intakeID: String
        let site: InjectionSite
        let takenAt: Date

        var id: String {
            "\(localID)|\(intakeID)"
        }
    }

    /// Proposals, newest dose first. Each local row and each dose take part in
    /// at most one, the closest pairs first.
    static func offers(
        medicationID: String,
        localSites: [InjectionSiteEntrySnapshot],
        intakes: [PaginatedIntakeEvent],
        window: TimeInterval = window
    ) -> [Offer] {
        let candidates = localSites.compactMap { row -> (InjectionSiteEntrySnapshot, InjectionSite)? in
            guard row.medicationID == medicationID,
                  let site = row.site, site != .unknown, site.serverRawValue != nil else { return nil }
            return (row, site)
        }
        let open = intakes.compactMap { intake -> (PaginatedIntakeEvent, Date)? in
            guard !intake.skipped, let takenAt = intake.takenAt, !hasSite(intake) else { return nil }
            return (intake, takenAt)
        }
        var pairs: [(distance: TimeInterval, offer: Offer)] = []
        for (row, site) in candidates {
            for (intake, takenAt) in open {
                let distance = abs(row.injectedAt.timeIntervalSince(takenAt))
                guard distance <= window else { continue }
                pairs.append((distance, Offer(localID: row.id, intakeID: intake.id, site: site, takenAt: takenAt)))
            }
        }
        pairs.sort { lhs, rhs in
            lhs.distance != rhs.distance ? lhs.distance < rhs.distance : lhs.offer.id < rhs.offer.id
        }
        var usedLocal = Set<String>()
        var usedIntake = Set<String>()
        var result: [Offer] = []
        for pair in pairs where !usedLocal.contains(pair.offer.localID) && !usedIntake.contains(pair.offer.intakeID) {
            usedLocal.insert(pair.offer.localID)
            usedIntake.insert(pair.offer.intakeID)
            result.append(pair.offer)
        }
        return result.sorted { $0.takenAt > $1.takenAt }
    }

    private static func hasSite(_ intake: PaginatedIntakeEvent) -> Bool {
        guard let raw = intake.injectionSite else { return false }
        return !raw.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
