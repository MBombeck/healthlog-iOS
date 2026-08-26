import Foundation
@testable import HealthLog
import Testing

/// **SAFETY — crisis-card contact-link + item-9 gating logic (audit H6).**
///
/// `MentalHealthCrisisCard` renders a ``CrisisResourceSet``: each contact line
/// becomes a tappable `tel:` / `https:` link where the shape is unambiguous, and
/// plain text otherwise (e.g. an SMS instruction). The store proves the card is
/// *requested* on a positive item-9; this suite proves the pure sub-logic paints
/// the RIGHT actionable links for the real bundled data, and that the gate keys on
/// item-9 ALONE — never on the total / severity band.
///
/// Pure (no network) → no `.serialized`, no global handler.
@Suite("Crisis-card logic (link shape + item-9 gating)")
struct MentalHealthCrisisCardLogicTests {
    // MARK: - link(for:) — canonical shapes

    @Test("phone digits (+ spaces) → tel: with spaces stripped", arguments: [
        ("0800 111 0 111", "tel:08001110111"),
        ("0800 111 0 222", "tel:08001110222"),
        ("116 111", "tel:116111"),
        ("116 123", "tel:116123"),
        ("988", "tel:988"),
        ("911", "tel:911"),
        ("112", "tel:112")
    ])
    func phoneLinesBecomeTel(_ input: String, _ expected: String) {
        #expect(MentalHealthCrisisCard.link(for: input)?.absoluteString == expected)
    }

    @Test("bare domain → https: (lowercased)", arguments: [
        ("telefonseelsorge.de", "https://telefonseelsorge.de"),
        ("krisenchat.de", "https://krisenchat.de"),
        ("findahelpline.com", "https://findahelpline.com"),
        ("FindAHelpline.com", "https://findahelpline.com")
    ])
    func domainsBecomeHttps(_ input: String, _ expected: String) {
        #expect(MentalHealthCrisisCard.link(for: input)?.absoluteString == expected)
    }

    @Test("ambiguous / instructional text → nil (plain text, no link)", arguments: [
        "Text HOME to 741741", // US Crisis Text Line — words + digits, not a dialable line
        "Rufe 0800 111 0 111 an", // free-text with a number embedded → not a bare number
        "", // empty
        "   " // whitespace only
    ])
    func instructionsRemainPlainText(_ input: String) {
        #expect(MentalHealthCrisisCard.link(for: input) == nil)
    }

    // MARK: - Every bundled contact resolves to the correct actionable link

    /// The card is only as safe as the links it actually paints. For each of the
    /// three bundled sets, assert every contact line resolves the way the card will
    /// render it — a dead `tel:` or a mis-linked instruction is a safety defect.
    @Test("Germany — every bundled contact resolves to the expected link kind")
    func germanyContactsResolve() {
        let de = CrisisResourceFallback.forLocale("de")
        assertLink(de, id: "telefonSeelsorge", contact: "0800 111 0 111", is: .tel("tel:08001110111"))
        assertLink(de, id: "telefonSeelsorge", contact: "0800 111 0 222", is: .tel("tel:08001110222"))
        assertLink(de, id: "telefonSeelsorge", contact: "telefonseelsorge.de", is: .https("https://telefonseelsorge.de"))
        assertLink(de, id: "nummerGegenKummer", contact: "116 111", is: .tel("tel:116111"))
        assertLink(de, id: "krisenchat", contact: "krisenchat.de", is: .https("https://krisenchat.de"))
        assertLink(de, id: "findahelpline", contact: "findahelpline.com", is: .https("https://findahelpline.com"))
    }

    @Test("United States — 988 dials, findahelpline links, Crisis Text Line stays plain")
    func unitedStatesContactsResolve() {
        let us = CrisisResourceFallback.forLocale("en-US")
        assertLink(us, id: "lifeline988", contact: "988", is: .tel("tel:988"))
        assertLink(us, id: "crisisTextLine", contact: "Text HOME to 741741", is: .plain)
        assertLink(us, id: "findahelpline", contact: "findahelpline.com", is: .https("https://findahelpline.com"))
    }

    @Test("International — EU emotional-support line dials, findahelpline links")
    func internationalContactsResolve() {
        let intl = CrisisResourceFallback.forLocale("en")
        assertLink(intl, id: "euEmotionalSupport", contact: "116 123", is: .tel("tel:116123"))
        assertLink(intl, id: "findahelpline", contact: "findahelpline.com", is: .https("https://findahelpline.com"))
    }

    @Test("every contact in every bundled set resolves without trapping (total over real data)")
    func allBundledContactsResolveTotally() {
        for locale in ["de", "en-US", "en"] {
            let set = CrisisResourceFallback.forLocale(locale)
            for resource in set.resources {
                for contact in resource.contacts {
                    // link(for:) is total: it returns a URL or nil, never crashes,
                    // and any URL it returns is a tel: or https: scheme.
                    if let url = MentalHealthCrisisCard.link(for: contact) {
                        #expect(url.scheme == "tel" || url.scheme == "https")
                    }
                }
            }
        }
    }

    // MARK: - Item-9 gating NEVER keys on total / band

    /// The crisis signpost fires strictly on item-9 (`items[8] > 0`) — independent
    /// of the total and the derived severity band. Sweep the full PHQ-9 total range:
    /// item-9 == 0 must NEVER flag (even at a max non-item-9 total), and any positive
    /// item-9 must ALWAYS flag (even when the total lands in the "minimal" band).
    @Test("item-9 == 0 never flags across the full total/band range")
    func item9ZeroNeverFlags() {
        let phq9 = MentalHealthInstrument.phq9
        // Pile score onto items 1–8, keep item-9 (index 8) at 0. Walk 0…24.
        for filled in 0 ... 8 {
            var items = Array(repeating: 0, count: 9)
            for i in 0 ..< filled {
                items[i] = 3
            } // up to 8×3 = 24 total, band up to "severe"
            let total = MentalHealthInstrument.scoreTotal(items)
            #expect(
                !phq9.isSafetyFlagged(items: items),
                "item-9 == 0 must not flag (total \(total), band \(phq9.severityBand(forTotal: total)))"
            )
        }
    }

    @Test("any positive item-9 always flags, even in the minimal band", arguments: 1 ... 3)
    func positiveItem9AlwaysFlags(_ item9: Int) {
        let phq9 = MentalHealthInstrument.phq9
        // All other items 0 → total == item9 (minimal band), yet flagged.
        var items = Array(repeating: 0, count: 9)
        items[8] = item9
        let total = MentalHealthInstrument.scoreTotal(items)
        #expect(phq9.isSafetyFlagged(items: items))
        #expect(phq9.severityBand(forTotal: total) == "minimal") // proves gate ≠ band
        #expect(total < phq9.actionThreshold) // proves gate ≠ actionThreshold
    }

    // MARK: - Helpers

    private enum ExpectedLink: Equatable {
        case tel(String)
        case https(String)
        case plain
    }

    private func assertLink(
        _ set: CrisisResourceSet,
        id: String,
        contact: String,
        is expected: ExpectedLink,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        // The contact line must actually be present in the bundled set (guards
        // against a fixture drift silently skipping the assertion).
        let resource = set.resources.first { $0.id == id }
        #expect(resource != nil, "resource \(id) missing from set", sourceLocation: sourceLocation)
        #expect(
            resource?.contacts.contains(contact) == true,
            "contact '\(contact)' missing from resource \(id)",
            sourceLocation: sourceLocation
        )

        let url = MentalHealthCrisisCard.link(for: contact)
        switch expected {
        case let .tel(value):
            #expect(url?.absoluteString == value, sourceLocation: sourceLocation)
        case let .https(value):
            #expect(url?.absoluteString == value, sourceLocation: sourceLocation)
        case .plain:
            #expect(url == nil, sourceLocation: sourceLocation)
        }
    }
}
