import CoreGraphics
import Foundation
@testable import HealthLog
import Testing

/// Locks the **Withings stroke proportion** for `HLRing` — 8.5 % of the ring's
/// shorter side, with a hard floor at 6 pt to prevent „Faden"-Optik bei
/// Mini-Rings (Skeleton placeholders, future 1×1-Tile activity rings).
///
/// Vertragsgrundlage: `.planning/v05x-marathon/R2-visual-design-spec.md` §
/// "Primitive #2 — HLRing". Die Funktion ist als pure `static` extrahiert,
/// damit hier ohne SwiftUI-Host getestet werden kann.
///
/// Cross-screen consistency: jeder Ring app-wide (`HealthScoreTile` 92 pt,
/// `ComplianceRingCard` 92 pt, hypothetische 60 pt Activity-Mini-Rings, 140 pt
/// Hero-Variante) bezieht seine Linienstärke aus dieser einen Quelle — bricht
/// dieser Test, bricht das Rhythm-Gefühl auf allen Surfaces gleichzeitig.
@Suite("HLRing stroke derivation contract")
struct HLRingStrokeTests {
    @Test("60 pt ring clamps to 6 pt floor (rohwert 5.1 → floor)")
    func smallRing() {
        // Roh: 60 × 0.085 = 5.1, aber unterhalb der 6-pt-Floor — schützt
        // Mini-Rings (Skeleton, hypothetische 1×1-Tile-Activity-Rings) vor
        // "Faden-Optik". Boundary liegt bei side ≈ 70.59.
        let stroke = HLRing.derivedStroke(forSide: 60)
        #expect(stroke == 6)
    }

    @Test("92 pt ring → ~7.82 pt stroke (HealthScore + Compliance)")
    func tileRing() {
        // Beide produktiven Callsites (`HealthScoreLoaded`, `ComplianceRingCard`)
        // setzen `.frame(width: 92, height: 92)` — dieser Test sichert genau
        // den Wert, den der Operator auf seinem iPhone sieht.
        let stroke = HLRing.derivedStroke(forSide: 92)
        #expect(abs(stroke - 7.82) < 0.01)
    }

    @Test("140 pt ring → ~11.9 pt stroke (Hero variant)")
    func heroRing() {
        let stroke = HLRing.derivedStroke(forSide: 140)
        #expect(abs(stroke - 11.9) < 0.01)
    }

    @Test("32 pt micro ring clamps to 6 pt floor (not 2.72 pt)")
    func microRingFloor() {
        // 32 × 0.085 = 2.72, das wäre als Stroke „Faden-Optik". Der `max(6, …)`-
        // Floor schützt Skeleton-Placeholder und potentielle 1×1-Tile-Rings.
        let stroke = HLRing.derivedStroke(forSide: 32)
        #expect(stroke == 6)
    }

    @Test("70.59 pt boundary ring exactly hits the 6 pt floor")
    func boundaryRing() {
        // side × 0.085 == 6 ⇒ side == 70.5882…  — direkt unter dieser Schwelle
        // greift der Floor, direkt darüber die Proportion.
        let belowBoundary = HLRing.derivedStroke(forSide: 70)
        let aboveBoundary = HLRing.derivedStroke(forSide: 72)
        #expect(belowBoundary == 6)
        #expect(abs(aboveBoundary - 6.12) < 0.01)
    }

    @Test("strokeRatio constant matches Withings 8.5 % reference")
    func strokeRatioConstant() {
        // Lock auf 8.5 % — bricht dieser Test, hat jemand die Proportion
        // angefasst ohne R2-Spec-Update.
        #expect(HLRing.strokeRatio == 0.085)
        #expect(HLRing.minStroke == 6)
    }

    @Test("valueMinimumScale lets the value shrink to 60 % before anything is cut")
    func valueMinimumScaleConstant() {
        // Public issue #6 — the centre value is single-line and scales down
        // instead of wrapping. Raising this floor brings the wrap back for the
        // longest realistic compliance value ("11/11"); lowering it lets the
        // number shrink under the legible-numeral threshold. The layout side of
        // the contract is verified by `HLRingValueLayoutTests`.
        #expect(HLRing.valueMinimumScale == 0.6)
    }

    @Test("the value grows with Dynamic Type until the inner diameter caps it")
    func valueFontGrowsThenCaps() {
        // Public issue #6, round 2 — `fontRatio` is a `@ScaledMetric`; at
        // accessibility sizes it nearly doubles (0.22 → ≈ 0.456 at AX5) while
        // the ring stays 92 pt. The font follows Dynamic Type up to
        // `valueFontCap` of the inner diameter and stands still beyond it.
        let side: CGFloat = 92
        let stroke = HLRing.derivedStroke(forSide: side)
        let inner = HLRing.innerDiameter(forSide: side, stroke: stroke)
        let cap = inner * HLRing.valueFontCap
        let standard = HLRing.valueFontSize(forSide: side, stroke: stroke, scaledRatio: 0.22)
        let larger = HLRing.valueFontSize(forSide: side, stroke: stroke, scaledRatio: 0.30)
        let ax5 = HLRing.valueFontSize(forSide: side, stroke: stroke, scaledRatio: 0.456)
        #expect(abs(standard - 20.24) < 0.01, "the default size is untouched by the cap")
        #expect(larger > standard, "bigger text still gets bigger text below the cap")
        #expect(abs(ax5 - cap) < 0.001, "past the cap the value stands still")
        #expect(HLRing.valueFontCap == 0.42)
    }

    @Test("five glyphs at the scale floor fit inside the inner diameter at 92 pt")
    func longestValueFitsAtTheFloor() {
        // "11/11" is five glyphs of the rounded bold face at ≈ 0.55 em each
        // (monospaced digits; the "/" is narrower, so this over-estimates).
        // Even when Dynamic Type drives the font to the cap, shrinking to
        // `valueMinimumScale` must leave the string inside the ring — that is
        // what keeps `lineLimit(1)` from answering with an ellipsis.
        let side: CGFloat = 92
        let stroke = HLRing.derivedStroke(forSide: side)
        let inner = HLRing.innerDiameter(forSide: side, stroke: stroke)
        let capped = HLRing.valueFontSize(forSide: side, stroke: stroke, scaledRatio: 0.456)
        let widthAtFloor = 5 * 0.55 * capped * HLRing.valueMinimumScale
        #expect(widthAtFloor < inner, "\(widthAtFloor) pt of glyphs do not fit \(inner) pt")
    }
}
