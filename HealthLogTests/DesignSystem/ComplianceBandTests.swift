import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// v0.12 W4-1 — locks the SINGLE compliance-band source of truth.
///
/// Before W4-1 the same adherence percentage was classified three different
/// ways across three med surfaces (detail KPI ≥0.9 green-topped ratio ramp;
/// card + Insights ≥70 graphite-topped percent ramp), so a med at 75 % read a
/// different colour depending on the screen. These tests pin:
///   1. the one threshold set (graphite ≥70 / warn 40-69 / bad <40),
///   2. that the `Int`-percent and `Double`-ratio entry points agree at every
///      boundary (the three call sites — `MedicationDetailSections` uses the
///      ratio path, `ActiveMedicationRow` + `InsightsMedicationsPage` use the
///      percent path — therefore can never disagree),
///   3. the monochrome doctrine: `.good` resolves to graphite (`HLText.primary`),
///      NOT a green signal.
@Suite("ComplianceBand — one threshold set, three call sites agree")
struct ComplianceBandTests {
    // MARK: - Integer-percent thresholds (card + Insights surfaces)

    @Test("≥70 % is .good (graphite — the healthy baseline carries no signal)")
    func goodBand() {
        #expect(ComplianceBand.band(forPercent: 70) == .good)
        #expect(ComplianceBand.band(forPercent: 75) == .good)
        #expect(ComplianceBand.band(forPercent: 90) == .good)
        #expect(ComplianceBand.band(forPercent: 100) == .good)
    }

    @Test("40-69 % is .warn")
    func warnBand() {
        #expect(ComplianceBand.band(forPercent: 40) == .warn)
        #expect(ComplianceBand.band(forPercent: 55) == .warn)
        #expect(ComplianceBand.band(forPercent: 69) == .warn)
    }

    @Test("<40 % is .bad")
    func badBand() {
        #expect(ComplianceBand.band(forPercent: 39) == .bad)
        #expect(ComplianceBand.band(forPercent: 0) == .bad)
        #expect(ComplianceBand.band(forPercent: -5) == .bad)
    }

    // MARK: - The pre-W4-1 contradiction is gone

    @Test("75 % no longer reads warn on detail while graphite elsewhere — it is .good everywhere")
    func seventyFivePercentIsConsistent() {
        // The detail KPI used a Double ratio; the card + Insights used Int
        // percent. Both now route through this one type, so 0.75 / 75 agree.
        #expect(ComplianceBand.band(forPercent: 75) == .good)
        #expect(ComplianceBand.band(forRatio: 0.75) == .good)
    }

    @Test("90 % no longer paints green on detail — it is .good (graphite) on every surface")
    func ninetyPercentIsGraphiteNotGreen() {
        #expect(ComplianceBand.band(forRatio: 0.90) == .good)
        #expect(ComplianceBand.band(forPercent: 90) == .good)
        // Doctrine: .good is graphite, not the statusOK green the detail KPI used.
        #expect(ComplianceBand.good.color == HLText.primary)
        #expect(ComplianceBand.good.color != HLColor.statusOK)
    }

    // MARK: - Ratio ↔ percent agree at every boundary

    @Test("ratio path and percent path agree at the 70 / 40 boundaries")
    func ratioAndPercentAgreeAtBoundaries() {
        #expect(ComplianceBand.band(forRatio: 0.70) == ComplianceBand.band(forPercent: 70))
        #expect(ComplianceBand.band(forRatio: 0.699) == ComplianceBand.band(forPercent: 69))
        #expect(ComplianceBand.band(forRatio: 0.40) == ComplianceBand.band(forPercent: 40))
        #expect(ComplianceBand.band(forRatio: 0.399) == ComplianceBand.band(forPercent: 39))
        // Exhaustive sweep: every integer percent classifies identically whether
        // fed as an Int or as the equivalent ratio.
        for pct in 0 ... 100 {
            #expect(
                ComplianceBand.band(forPercent: pct) == ComplianceBand.band(forRatio: Double(pct) / 100.0)
            )
        }
    }

    // MARK: - Colour mapping (signal only)

    @Test("colour mapping: good=graphite, warn=statusWarn, bad=statusBad")
    func colourMapping() {
        #expect(ComplianceBand.good.color == HLText.primary)
        #expect(ComplianceBand.warn.color == HLColor.statusWarn)
        #expect(ComplianceBand.bad.color == HLColor.statusBad)
    }

    // MARK: - W-B187 coherence — detail KPI %-text and band-colour agree at x.5

    /// The detail-KPI text renders `ComplianceSummary.percentage`
    /// (`(ratio*100).rounded()`, half-away). The colour swatch (`bandColor` in
    /// `MedicationDetailSections`) now derives from that SAME integer via
    /// `band(forPercent:)`. Before W-B187 the colour re-rounded the ratio with
    /// `.towardZero`, so at a ratio whose percent lands exactly on x.5 ON a band
    /// boundary the text and its colour could disagree by one band (e.g. 69.5 %
    /// → text "70 %"/`.good` but colour `.warn`). This pins that the band the KPI
    /// paints is always the band the displayed integer implies.
    @Test("at an x.5 boundary the displayed integer and its band colour agree")
    func detailKPITextAndBandAgreeAtHalfBoundary() {
        // 139/200 = 0.695 → 69.5 % → .rounded() → 70 (text), .towardZero → 69.
        // The OLD ratio-rounding would have classified on 69 (.warn) while the
        // text read "70 %" (.good). The fix classifies on the displayed integer.
        let near70 = MedicationDetailStore.ComplianceSummary(inTime: 139, total: 200)
        #expect(near70.percentage == 70)
        #expect(ComplianceBand.band(forPercent: near70.percentage) == .good)

        // 79/200 = 0.395 → 39.5 % → .rounded() → 40 (text, .warn); the OLD path
        // truncated to 39 (.bad). Again: band follows the displayed integer.
        let near40 = MedicationDetailStore.ComplianceSummary(inTime: 79, total: 200)
        #expect(near40.percentage == 40)
        #expect(ComplianceBand.band(forPercent: near40.percentage) == .warn)

        // Exhaustive: for EVERY (inTime,total) the band the KPI paints is the band
        // its DISPLAYED integer implies — never a separately re-rounded ratio.
        // Wherever the half-away text ("\(percentage)%") and the toward-zero
        // ratio path would have classified into different bands (the x.5
        // boundary cases), this pins the painted band to the text's integer.
        for total in 1 ... 200 {
            for inTime in 0 ... total {
                let summary = MedicationDetailStore.ComplianceSummary(inTime: inTime, total: total)
                #expect((0 ... 100).contains(summary.percentage))
                let paintedBand = ComplianceBand.band(forPercent: summary.percentage)
                let textImpliedBand = ComplianceBand.band(forPercent: Int("\(summary.percentage)") ?? -1)
                #expect(paintedBand == textImpliedBand)
            }
        }
    }

    /// Non-boundary integers keep their established band — the fix only changes
    /// the rounding *source*, never the threshold contract.
    @Test("non-boundary percentages keep their bands (thresholds unchanged)")
    func nonBoundaryBandsUnchanged() {
        #expect(ComplianceBand.band(forPercent: 71) == .good)
        #expect(ComplianceBand.band(forPercent: 68) == .warn)
        #expect(ComplianceBand.band(forPercent: 41) == .warn)
        #expect(ComplianceBand.band(forPercent: 38) == .bad)
    }
}
