import Foundation
#if canImport(CoreSpotlight)
    import CoreSpotlight
#endif
#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

/// **W-B187 QOL-2 — pure builder for HealthLog CoreSpotlight items.**
///
/// Turns a medication or a measured-kind into a `CSSearchableItem` whose
/// `uniqueIdentifier` IS the app's own `healthlog://` deep-link — so the
/// continuation handler can hand the id straight to `DeepLinkRouter`
/// without a side table. Kept pure (no index I/O, no stores) so the
/// id / deep-link / PHI-safety rules are unit-testable in isolation.
///
/// **Privacy — the load-bearing rule.** Spotlight content is system-indexed
/// and surfaces in the OS search UI, so it must carry **NO health VALUES /
/// PHI**. We index:
///   - a **medication name** (a label the user typed — fine to surface,
///     and the whole point of "search my meds"), plus neutral keywords;
///   - a **measured-kind title** ("Blood pressure", "Weight") — a neutral
///     category label, **never the reading itself**. No systolic/diastolic,
///     no kg, no glucose number ever reaches the searchable text.
/// The deep-link in `uniqueIdentifier` routes to the right screen; the
/// actual values are shown only after the user is back inside the app
/// (behind the app's own gates).
enum SpotlightItemBuilder {
    /// The CoreSpotlight domain HealthLog owns. Used to batch-delete the
    /// whole index on logout / re-index, so a stale med name can't linger
    /// in system search after the user signs out.
    static let domainIdentifier = "dev.healthlog.app.spotlight"

    /// Sub-domains let us re-index one content class without nuking the
    /// other (meds change far more often than the measured-kind set).
    enum Domain: String {
        case medications = "dev.healthlog.app.spotlight.medications"
        case measurements = "dev.healthlog.app.spotlight.measurements"
    }

    // MARK: - Deep-link identifiers (pure, no CoreSpotlight needed)

    /// The `healthlog://medications/<id>` deep-link that doubles as the
    /// Spotlight `uniqueIdentifier`. `nil` for an id that fails the
    /// deep-link allowlist (so a tampered/odd id never produces a routable
    /// item — the continuation would drop it anyway).
    static func medicationDeepLink(id: String) -> String? {
        guard isRoutableID(id) else { return nil }
        return "healthlog://medications/\(id)"
    }

    /// The `healthlog://insights/<slug>` deep-link for a measured kind. The
    /// caller supplies the canonical Insights slug (computed app-side via
    /// `InsightsTabSlug.slug(forKind:)`); a kind with no Insights page
    /// yields `nil` and is simply not indexed.
    static func measurementDeepLink(slug: String) -> String? {
        guard isMetricSlug(slug) else { return nil }
        return "healthlog://insights/\(slug)"
    }

    /// Mirrors `DeepLinkRoute.idAllowlist` so an id we'd build a Spotlight
    /// item for is exactly an id the router would accept (`[A-Za-z0-9_-]`,
    /// 1–64). Keeps the two surfaces from drifting.
    static func isRoutableID(_ candidate: String) -> Bool {
        guard (1 ... 64).contains(candidate.count) else { return false }
        return candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Mirrors `DeepLinkRoute.metricSlugAllowlist` (`[a-z0-9-]`, 1–48).
    static func isMetricSlug(_ candidate: String) -> Bool {
        guard (1 ... 48).contains(candidate.count) else { return false }
        return candidate.allSatisfy { $0.isASCII && (($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-") }
    }

    /// **PHI guard (pure, testable).** A defensive predicate the indexer
    /// asserts before handing any string to Spotlight: rejects content that
    /// *looks like* a reading — a digit run (e.g. "120/80", "72.4") is the
    /// signature of a value leaking into searchable text. Med NAMES and the
    /// neutral kind titles we index contain no digit runs, so a future edit
    /// that accidentally interpolated a value would trip this in tests +
    /// be dropped at runtime rather than indexed.
    static func looksLikeContainsPHI(_ text: String) -> Bool {
        var digitRun = 0
        for character in text {
            if character.isNumber {
                digitRun += 1
                if digitRun >= 2 { return true }
            } else {
                digitRun = 0
            }
        }
        return false
    }

    #if canImport(CoreSpotlight)
        /// Build the searchable item for a medication. `title` is the med
        /// name; `keywords` are neutral search aids. Returns `nil` when the
        /// id isn't routable or the title would carry PHI (defensive).
        static func medicationItem(id: String, name: String) -> CSSearchableItem? {
            guard let deepLink = medicationDeepLink(id: id) else { return nil }
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.isEmpty == false, looksLikeContainsPHI(title) == false else { return nil }

            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = title
            attributes.contentDescription = String(
                localized: "spotlight.medication.subtitle",
                defaultValue: "Medication in HealthLog",
                comment: "CoreSpotlight — medication item subtitle (neutral, no PHI)"
            )
            attributes.keywords = medicationKeywords(name: title)
            return CSSearchableItem(
                uniqueIdentifier: deepLink,
                domainIdentifier: Domain.medications.rawValue,
                attributeSet: attributes
            )
        }

        /// Build the searchable item for a measured kind. `title` is the
        /// neutral localized kind name ("Blood pressure"); `slug` is its
        /// Insights deep-link slug. **No value ever crosses into the
        /// attributes** — only the category label + deep-link.
        static func measurementItem(slug: String, title: String) -> CSSearchableItem? {
            guard let deepLink = measurementDeepLink(slug: slug) else { return nil }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, looksLikeContainsPHI(trimmed) == false else { return nil }

            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = trimmed
            attributes.contentDescription = String(
                localized: "spotlight.measurement.subtitle",
                defaultValue: "Open in HealthLog Insights",
                comment: "CoreSpotlight — measurement-kind item subtitle (neutral, no PHI)"
            )
            attributes.keywords = measurementKeywords(title: trimmed)
            return CSSearchableItem(
                uniqueIdentifier: deepLink,
                domainIdentifier: Domain.measurements.rawValue,
                attributeSet: attributes
            )
        }
    #endif

    /// Neutral keyword aids for a medication item — the brand/app name plus
    /// the words a user might type. PHI-free by construction (the name is a
    /// user-typed label, not a reading).
    static func medicationKeywords(name: String) -> [String] {
        [
            name,
            String(localized: "spotlight.keyword.medication", defaultValue: "medication", comment: "CoreSpotlight keyword — medication"),
            String(localized: "spotlight.keyword.dose", defaultValue: "dose", comment: "CoreSpotlight keyword — dose"),
            "HealthLog"
        ]
    }

    /// Neutral keyword aids for a measured-kind item.
    static func measurementKeywords(title: String) -> [String] {
        [
            title,
            String(localized: "spotlight.keyword.measurement", defaultValue: "measurement", comment: "CoreSpotlight keyword — measurement"),
            String(localized: "spotlight.keyword.insights", defaultValue: "insights", comment: "CoreSpotlight keyword — insights"),
            "HealthLog"
        ]
    }
}
