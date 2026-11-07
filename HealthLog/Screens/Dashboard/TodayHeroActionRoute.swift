import Foundation

/// **Where a "worth a look" rail action leads**, decided from its stable
/// `intent` (and, where the intent says so, its web `href`). Pure, so the map
/// is testable without the hero's environment; ``TodayHeroHost`` performs it.
///
/// The coach check-in's keep / let-go are the only MUTATING intents (they
/// carry the plan id after the ":"); every other intent is pure navigation.
/// An unknown intent that still carries an in-app insights href goes there;
/// otherwise it is a no-op, never a dead tap into a web path.
enum TodayHeroActionRoute: Equatable {
    case coachKeep(planId: String)
    case coachLetGo(planId: String)
    case coach
    /// The upcoming-intakes sheet (Wave 2 / 2.5).
    case intakes
    case integrations
    /// `checkup.view`: straight to doing the due check-up where it can be
    /// captured, else the Vorsorge list (Wave 2 / 2.6, v1.39.2).
    case checkupFrontDoor
    /// **#149 (server 1.44.0)** — `visit.view`: an upcoming appointment.
    /// Its `href` names the visit (`/checkups?visit=<id>`) or the visit list
    /// (`/checkups?view=visits`); the app has neither screen yet, so both open
    /// the Vorsorge list, as the appointment's `checkup.view` did before.
    case checkupsList
    /// VISIT — `visit.view` whose `href` names one visit
    /// (`/checkups?visit=<id>`): Vorsorge, with that visit under "Nächster
    /// Termin". Several visits (`?view=visits`) stay ``checkupsList``.
    case visit(id: String)
    case insightsOverview
    case insights(slug: String)
    case none

    static let coachKeepPrefix = "coach.checkin.keep:"
    static let coachLetGoPrefix = "coach.checkin.letGo:"

    static func resolve(intent: String, href: String?) -> TodayHeroActionRoute {
        if let id = planId(from: intent, prefix: coachKeepPrefix) { return .coachKeep(planId: id) }
        if let id = planId(from: intent, prefix: coachLetGoPrefix) { return .coachLetGo(planId: id) }
        switch intent {
        // Adjust opens the Coach (web seeds the composer via `?ask=`; the iOS
        // seed hand-off is a follow-up).
        case "coach.checkin.adjust": return .coach
        case "dose.log": return .intakes
        case "sync.reconnect": return .integrations
        case "checkup.view": return .checkupFrontDoor
        case "visit.view":
            if case let .checkupsVisit(id) = DeepLinkRoute.fromPushPath(href ?? "") { return .visit(id: id) }
            return .checkupsList
        case "ecg.view": return .insightsOverview
        case "milestone.view", "pulse.view":
            return insightsSlug(from: href).map { .insights(slug: $0) } ?? .insightsOverview
        default:
            return insightsSlug(from: href).map { .insights(slug: $0) } ?? .none
        }
    }

    /// The plan id appended after a mutating coach intent's prefix.
    static func planId(from intent: String, prefix: String) -> String? {
        guard intent.hasPrefix(prefix) else { return nil }
        let id = String(intent.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// An Insights metric slug from a web `/insights/<slug>` (or
    /// `/insights#<frag>`) href; `nil` means the Insights overview.
    static func insightsSlug(from href: String?) -> String? {
        guard let href, href.contains("/insights") else { return nil }
        if let range = href.range(of: "/insights/") {
            let slug = href[range.upperBound...].prefix { $0 != "?" && $0 != "#" && $0 != "/" }
            return slug.isEmpty ? nil : String(slug)
        }
        if let hashIndex = href.firstIndex(of: "#") {
            let frag = href[href.index(after: hashIndex)...]
            return frag.isEmpty ? nil : String(frag)
        }
        return nil
    }
}
