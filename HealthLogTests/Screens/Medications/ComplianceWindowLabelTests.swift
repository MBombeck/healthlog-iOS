import Foundation
@testable import HealthLog
import Testing

/// **W-B184 AS-1 — compliance window-label coherence.**
///
/// The recurring operator complaint ("compliance isn't computed right" /
/// "90d looks like 365d") was a *labeling* problem: three different server
/// metrics (today-raw, cadence-scaled, 30-day in-time) were painted as bare
/// percentages, so the same medication legitimately read e.g. 86 / 87 / 75
/// on adjacent surfaces with nothing telling the user which window each number
/// covered. The server ledger stays authoritative — this fix only adds an
/// explicit window/context label next to every compliance percentage.
///
/// These tests pin the localized window-label format strings so a future
/// edit can't silently drop the window context (turning a compliance readout
/// back into a bare, ambiguous number) without a red test.
///
/// **08-13 — the two compact-row cases moved onto the card.** They pinned the
/// dense alternate row's chip suffix and its VoiceOver label; 08-13 deleted
/// that row along with the presentation branch that mounted it, and the two
/// `med.table.*` keys went with it in the same commit. The claim the suite
/// exists for — a compliance percentage is never spoken or shown without the
/// window it covers — is not weaker for it, because the card carries the same
/// obligation on the surface a user can actually reach, and the first case
/// below now states it against the surviving key pair.
@Suite("Compliance window labels — AS-1")
struct ComplianceWindowLabelTests {
    /// The card's compliance VoiceOver label must name BOTH the window and the
    /// percent, so a non-sighted user gets the same disambiguation the visible
    /// bar carries. This is the composition `MedicationCard`
    /// (`ActiveMedicationRow.accessibilityCardLabel`) actually performs: the
    /// window label is formatted first and substituted into `%1$@`.
    @Test("Card compliance a11y label names window and percent")
    func cardAccessibilityLabelNamesWindowAndPercent() {
        let window = String(
            format: String(localized: "med.card.compliance.window.label"),
            90
        )
        let label = String(
            format: String(localized: "med.card.compliance.a11y"),
            window,
            87
        )
        #expect(label.contains("90"))
        #expect(label.contains("87"))
        // The window must survive the substitution as words, not just as a
        // digit — a bare "90: 87 …" would be the ambiguity this suite exists
        // to forbid.
        #expect(label.count > window.count)
    }

    /// The detail KPI trailing label must name the in-time metric, not just
    /// the window — otherwise the detail headline (30-day in-time) looks
    /// contradictory next to the card's raw cadence-scaled rate over a
    /// similar window.
    @Test("Detail KPI window label names the in-time metric")
    func detailKpiWindowLabel() {
        // Resolve in whatever localization the test bundle settles on (the CI
        // simulator's preferred language overrides a per-call `locale:`), then
        // assert the label names BOTH the window and the in-time qualifier —
        // that qualifier is what disambiguates the detail's stricter in-time
        // number from the card's raw cadence-scaled rate over a similar period.
        let label = String(localized: "med.compliance.window").lowercased()
        #expect(label.contains("30"))
        #expect(label.contains("pünktlich") || label.contains("on time"))
    }

    /// The card + Insights bars label each row with its own window day count;
    /// the format string must keep the `%lld` window slot.
    @Test("Card/Insights bar label carries the per-window day count")
    func cardWindowLabel() {
        let label = String(
            format: String(localized: "med.card.compliance.window.label"),
            30
        )
        #expect(label.contains("30"))
    }
}
