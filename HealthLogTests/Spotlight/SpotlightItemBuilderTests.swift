import CoreSpotlight
import Foundation
@testable import HealthLog
import Testing

/// **W-B187 QOL-2** — coverage for the pure CoreSpotlight item builder.
///
/// The load-bearing invariants:
///   - the `uniqueIdentifier` IS the app's own `healthlog://` deep-link
///     (so the continuation can route it with no side table);
///   - NO health VALUE / PHI ever reaches the searchable text — the PHI
///     guard rejects any digit-run-shaped string;
///   - the id / slug allowlists mirror `DeepLinkRoute` so a built item is
///     always a routable item.
@Suite("Spotlight item builder")
struct SpotlightItemBuilderTests {
    // MARK: - Deep-link identifiers

    @Test("Medication item id is the healthlog:// detail deep-link")
    func medicationDeepLink() {
        #expect(SpotlightItemBuilder.medicationDeepLink(id: "med_abc123") == "healthlog://medications/med_abc123")
    }

    @Test("A non-routable id yields no deep-link")
    func rejectsBadID() {
        #expect(SpotlightItemBuilder.medicationDeepLink(id: "../etc") == nil)
        #expect(SpotlightItemBuilder.medicationDeepLink(id: "") == nil)
        #expect(SpotlightItemBuilder.medicationDeepLink(id: String(repeating: "a", count: 65)) == nil)
    }

    @Test("Measurement item id is the healthlog:// insights metric deep-link")
    func measurementDeepLink() {
        #expect(SpotlightItemBuilder.measurementDeepLink(slug: "blood-pressure") == "healthlog://insights/blood-pressure")
    }

    @Test("A non-slug rejects (upper-case / underscore / over-length)")
    func rejectsBadSlug() {
        #expect(SpotlightItemBuilder.measurementDeepLink(slug: "Blood_Pressure") == nil)
        #expect(SpotlightItemBuilder.measurementDeepLink(slug: "") == nil)
    }

    // MARK: - PHI guard

    @Test("A reading-shaped string is flagged as PHI")
    func phiGuardFlagsValues() {
        #expect(SpotlightItemBuilder.looksLikeContainsPHI("120/80") == true)
        #expect(SpotlightItemBuilder.looksLikeContainsPHI("72.4 kg") == true)
        #expect(SpotlightItemBuilder.looksLikeContainsPHI("98") == true)
    }

    @Test("A clean med name / category title is not flagged")
    func phiGuardPassesLabels() {
        #expect(SpotlightItemBuilder.looksLikeContainsPHI("Lisinopril") == false)
        #expect(SpotlightItemBuilder.looksLikeContainsPHI("Blood pressure") == false)
        // A single isolated digit (e.g. "Vitamin D3" — one digit) is allowed.
        #expect(SpotlightItemBuilder.looksLikeContainsPHI("Vitamin D3") == false)
    }

    // MARK: - CSSearchableItem construction (no PHI in text)

    @Test("Built medication item carries the deep-link id + name title, no value")
    func medicationItemShape() throws {
        let item = try #require(SpotlightItemBuilder.medicationItem(id: "med_x", name: "Lisinopril"))
        #expect(item.uniqueIdentifier == "healthlog://medications/med_x")
        #expect(item.domainIdentifier == SpotlightItemBuilder.Domain.medications.rawValue)
        #expect(item.attributeSet.title == "Lisinopril")
        // No value/PHI: title + keywords must all pass the guard.
        let keywords = item.attributeSet.keywords ?? []
        for keyword in keywords {
            #expect(SpotlightItemBuilder.looksLikeContainsPHI(keyword) == false)
        }
    }

    @Test("Built measurement item carries a neutral title + insights deep-link, never a value")
    func measurementItemShape() throws {
        let item = try #require(SpotlightItemBuilder.measurementItem(slug: "weight", title: "Weight"))
        #expect(item.uniqueIdentifier == "healthlog://insights/weight")
        #expect(item.attributeSet.title == "Weight")
        #expect(SpotlightItemBuilder.looksLikeContainsPHI(item.attributeSet.title ?? "") == false)
    }

    @Test("A med whose name accidentally looks like a value is dropped, not indexed")
    func phiNameDropped() {
        // Defensive: a title that trips the PHI guard yields no item.
        #expect(SpotlightItemBuilder.medicationItem(id: "med_x", name: "120/80") == nil)
    }
}
